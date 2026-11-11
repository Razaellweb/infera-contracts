// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {InferaEthHook} from "./InferaEthHook.sol";

interface IInferaToken {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function totalSupply() external view returns (uint256);
    function initializer() external view returns (address);
    function poolManager() external view returns (address);
    function start() external;
}

/// @notice A Chainlink-style ETH/USD price feed.
interface IEthUsdFeed {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @title InferaLaunchInitializer
/// @notice Opens the INFERA/ETH pool inside the launch transaction, once:
///   1. initializes the pool at the starting price,
///   2. puts the whole INFERA supply (minted to this contract) into one position from the lowest
///      usable price up to the starting price, so the pool opens holding only INFERA and buyers'
///      ETH builds the other side,
///   3. checks the opening valuation is at least USD 15,000 against the live Chainlink ETH/USD
///      price (at most one hour old on Mainnet), as Programmable requires,
///   4. starts trading on the token, which opens the launch-protection window,
///   5. makes the launch wallet's (the developer's) first buy with the ETH sent to {initialize}.
///
/// Liquidity is locked permanently: this contract owns the position and has no way to remove it.
/// The position's earnings (the pool's LP fee) can be collected by anyone, and only ever go to
/// the hook's current buybacks recipient.
contract InferaLaunchInitializer is IUnlockCallback {
    using CurrencyLibrary for Currency;

    /// @notice The Uniswap v4 PoolManager.
    IPoolManager public immutable poolManager;
    /// @notice The only caller of {initialize}: the factory that deploys the launch (Programmable's
    ///         graph factory on Mainnet).
    address public immutable launcher;
    /// @notice The ETH/USD feed (Chainlink 0x5f4e...8419 on Mainnet), its code hash and decimals.
    IEthUsdFeed public immutable ethUsdFeed;
    bytes32 public immutable feedCodeHash;
    uint8 public immutable feedDecimals;
    /// @notice How old the feed's latest price may be: one hour on Mainnet, its heartbeat.
    uint256 public immutable maxFeedAge;

    /// @notice The lowest allowed opening fully diluted valuation, in USD.
    uint256 public constant MINIMUM_FDV_USD = 15_000;
    address public constant MAINNET_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant MAINNET_ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    InferaEthHook public hook;
    PoolKey internal poolKey_;
    int24 public tickLower;
    int24 public tickUpper;
    uint128 public lockedLiquidity;
    /// @notice The opening valuation the launch was checked at, in whole USD.
    uint256 public openingFdvUsd;
    bool public initialized;

    enum Action {
        Seed,
        Collect
    }

    event Launched(
        address indexed hook,
        address indexed token,
        int24 startTick,
        uint256 openingFdvUsd,
        uint128 liquidity,
        address indexed buyer,
        uint256 initialBuyEth,
        uint256 initialBuyInfera
    );
    event PoolFeesCollected(address indexed recipient, uint256 eth, uint256 infera);

    error ZeroAddress();
    error NotLauncher();
    error NotPoolManager();
    error AlreadyInitialized();
    error NotInitialized();
    error NoInitialBuy();
    error WrongToken();
    error MisalignedTick();
    error InitialBuyBelowMinimum(uint256 received, uint256 minimum);
    error InvalidConfiguration();
    error InvalidOraclePrice();
    error OpeningValuationTooLow(uint256 fdvUsd);

    constructor(IPoolManager manager_, address launcher_, IEthUsdFeed feed_, bytes32 expectedFeedCodeHash) {
        if (address(manager_) == address(0) || launcher_ == address(0)) revert ZeroAddress();
        if (
            (block.chainid == 1
                    && (address(manager_) != MAINNET_POOL_MANAGER || address(feed_) != MAINNET_ETH_USD_FEED))
                || address(manager_).code.length == 0 || address(feed_).code.length == 0
                || address(feed_).codehash != expectedFeedCodeHash
        ) revert InvalidConfiguration();
        uint8 decimals = feed_.decimals();
        if (decimals > 18) revert InvalidConfiguration();
        poolManager = manager_;
        launcher = launcher_;
        ethUsdFeed = feed_;
        feedCodeHash = expectedFeedCodeHash;
        feedDecimals = decimals;
        maxFeedAge = block.chainid == 1 ? 1 hours : 24 hours;
    }

    /// @notice Initializes the pool, seeds and locks the whole supply, and makes the first buy.
    /// @param hook_ The pool's hook; the pool key is the one it serves.
    /// @param token The INFERA token; must be the hook's currency1.
    /// @param startTick Starting price as a tick (INFERA per ETH), a multiple of the tick spacing.
    /// @param buyer Receives the first buy's INFERA; must be the hook's developer.
    /// @param minTokensOut The least INFERA the first buy may return (nonzero).
    function initialize(InferaEthHook hook_, address token, int24 startTick, address buyer, uint256 minTokensOut)
        external
        payable
    {
        if (msg.sender != launcher) revert NotLauncher();
        if (initialized) revert AlreadyInitialized();
        if (msg.value == 0 || minTokensOut == 0) revert NoInitialBuy();
        if (buyer == address(0)) revert ZeroAddress();
        PoolKey memory key = hook_.poolKey();
        if (Currency.unwrap(key.currency1) != token) revert WrongToken();
        if (startTick % key.tickSpacing != 0) revert MisalignedTick();
        if (
            IInferaToken(token).initializer() != address(this)
                || IInferaToken(token).poolManager() != address(poolManager) || hook_.initializer() != address(this)
                || hook_.developer() != buyer || address(hook_.poolManager()) != address(poolManager)
                || startTick <= TickMath.minUsableTick(key.tickSpacing)
                || startTick >= TickMath.maxUsableTick(key.tickSpacing)
        ) revert InvalidConfiguration();
        uint160 startPrice = TickMath.getSqrtPriceAtTick(startTick);
        openingFdvUsd = _openingFdvUsd(IInferaToken(token).totalSupply(), startPrice);
        if (openingFdvUsd < MINIMUM_FDV_USD) revert OpeningValuationTooLow(openingFdvUsd);

        initialized = true;
        hook = hook_;
        poolKey_ = key;
        tickLower = TickMath.minUsableTick(key.tickSpacing);
        tickUpper = startTick;

        // forge-lint: disable-next-line(unused-return) the returned tick is startTick
        poolManager.initialize(key, startPrice);
        // forge-lint: disable-next-line(unused-return) seeding returns nothing
        poolManager.unlock(abi.encode(Action.Seed, buyer, minTokensOut));
    }

    /// @notice Sends the locked position's earnings to the hook's buybacks recipient. Callable by anyone.
    function collectPoolFees() external returns (uint256 eth, uint256 infera) {
        if (!initialized) revert NotInitialized();
        (eth, infera) = abi.decode(poolManager.unlock(abi.encode(Action.Collect, address(0), 0)), (uint256, uint256));
    }

    /// @notice The pool this contract opened.
    function poolKey() external view returns (PoolKey memory) {
        return poolKey_;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (Action action, address buyer, uint256 minTokensOut) = abi.decode(data, (Action, address, uint256));
        return action == Action.Seed ? _seed(buyer, minTokensOut) : _collect();
    }

    function _seed(address buyer, uint256 minTokensOut) private returns (bytes memory) {
        PoolKey memory key = poolKey_;
        uint128 liquidity = _addLockedLiquidity(key);
        // Rounding the liquidity down can leave a few wei of INFERA here; they stay, unused.
        IInferaToken token = IInferaToken(Currency.unwrap(key.currency1));
        token.start();
        (uint256 ethUsed, uint256 inferaOut) = _firstBuy(key, buyer, minTokensOut);

        // forge-lint: disable-next-line(reentrancy-events) calls above go only to the PoolManager, INFERA and the hook
        emit Launched(address(hook), address(token), tickUpper, openingFdvUsd, liquidity, buyer, ethUsed, inferaOut);
        return "";
    }

    /// @dev The position sits entirely below the starting price, so it holds only INFERA:
    ///      liquidity = supply * 2^96 / (sqrtPriceUpper - sqrtPriceLower), rounded down.
    /// @dev The opening valuation in whole USD, rounded down: supply * (ETH per INFERA) * (USD per ETH).
    ///      ETH is currency0 and INFERA currency1, so ETH per INFERA = 2^192 / sqrtPrice^2.
    function _openingFdvUsd(uint256 supply, uint160 sqrtPriceX96) private view returns (uint256) {
        if (address(ethUsdFeed).codehash != feedCodeHash) revert InvalidOraclePrice();
        // forge-lint: disable-next-item(unused-return, block-timestamp) startedAt is unused; feed age is in seconds
        (uint80 round, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = ethUsdFeed.latestRoundData();
        // forge-lint: disable-next-item(block-timestamp) the feed's age is measured in seconds
        if (
            answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > maxFeedAge
                || answeredInRound < round || round == 0
        ) revert InvalidOraclePrice();
        uint256 supplyInEth;
        if (sqrtPriceX96 <= type(uint128).max) {
            supplyInEth = FullMath.mulDiv(uint256(1) << 192, supply, uint256(sqrtPriceX96) * sqrtPriceX96);
        } else {
            supplyInEth = FullMath.mulDiv(
                uint256(1) << 128, supply, FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, uint256(1) << 64)
            );
        }
        // forge-lint: disable-next-line(unsafe-typecast) answer > 0 was checked above
        return FullMath.mulDiv(supplyInEth, uint256(answer), 1 ether * 10 ** feedDecimals);
    }

    function _addLockedLiquidity(PoolKey memory key) private returns (uint128 liquidity) {
        IInferaToken token = IInferaToken(Currency.unwrap(key.currency1));
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        liquidity = SafeCast.toUint128(
            FullMath.mulDiv(token.balanceOf(address(this)), FixedPoint96.Q96, sqrtUpper - sqrtLower)
        );
        lockedLiquidity = liquidity;
        // forge-lint: disable-next-item(unused-return) a new position has no earnings yet
        (BalanceDelta added,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liquidity)), salt: 0
            }),
            ""
        );
        uint256 inferaOwed = SafeCast.toUint128(-added.amount1()); // adding liquidity owes INFERA
        poolManager.sync(key.currency1);
        // forge-lint: disable-next-line(erc20-unchecked-transfer) InferaToken reverts on failure
        token.transfer(address(poolManager), inferaOwed);
        // forge-lint: disable-next-line(unused-return) the settled amount is inferaOwed
        poolManager.settle();
    }

    /// @dev The ETH is paid in before the swap, so the hook can take its fees from it.
    function _firstBuy(PoolKey memory key, address buyer, uint256 minTokensOut)
        private
        returns (uint256 ethUsed, uint256 inferaOut)
    {
        uint256 ethIn = address(this).balance;
        int256 amountSpecified = -SafeCast.toInt256(ethIn);
        // forge-lint: disable-next-line(unused-return) the settled amount is ethIn
        poolManager.settle{value: ethIn}();
        BalanceDelta bought = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: amountSpecified, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        inferaOut = SafeCast.toUint128(bought.amount1()); // a buy receives INFERA
        if (inferaOut < minTokensOut) revert InitialBuyBelowMinimum(inferaOut, minTokensOut);
        poolManager.take(key.currency1, buyer, inferaOut);
        ethUsed = SafeCast.toUint128(-bought.amount0()); // a buy pays ETH
        if (ethUsed < ethIn) poolManager.take(CurrencyLibrary.ADDRESS_ZERO, buyer, ethIn - ethUsed);
    }

    function _collect() private returns (bytes memory) {
        PoolKey memory key = poolKey_;
        // A zero-liquidity update only collects the position's earnings; the liquidity stays locked.
        // forge-lint: disable-next-item(unused-return) the earnings are already in the caller delta
        (BalanceDelta earned,) = poolManager.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 0, salt: 0}), ""
        );
        address recipient = hook.buybacksRecipient();
        uint256 eth = SafeCast.toUint128(earned.amount0());
        uint256 infera = SafeCast.toUint128(earned.amount1());
        if (eth != 0) poolManager.take(CurrencyLibrary.ADDRESS_ZERO, recipient, eth);
        if (infera != 0) poolManager.take(key.currency1, recipient, infera);
        // forge-lint: disable-next-line(reentrancy-events) calls above go only to the PoolManager and the hook
        emit PoolFeesCollected(recipient, eth, infera);
        return abi.encode(eth, infera);
    }
}
