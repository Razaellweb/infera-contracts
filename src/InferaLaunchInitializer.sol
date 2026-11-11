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
}

/// @title InferaLaunchInitializer
/// @notice Opens the INFERA/ETH pool inside the launch transaction, once:
///   1. initializes the pool at the starting price,
///   2. puts the whole INFERA supply (minted to this contract) into one position from the lowest
///      usable price up to the starting price, so the pool opens holding only INFERA and buyers'
///      ETH builds the other side,
///   3. makes the launch wallet's first buy with the ETH sent to {initialize}.
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

    InferaEthHook public hook;
    PoolKey internal poolKey_;
    int24 public tickLower;
    int24 public tickUpper;
    uint128 public lockedLiquidity;
    bool public initialized;

    enum Action {
        Seed,
        Collect
    }

    event Launched(
        address indexed hook,
        address indexed token,
        int24 startTick,
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

    constructor(IPoolManager manager_, address launcher_) {
        if (address(manager_) == address(0) || launcher_ == address(0)) revert ZeroAddress();
        poolManager = manager_;
        launcher = launcher_;
    }

    /// @notice Initializes the pool, seeds and locks the whole supply, and makes the first buy.
    /// @param hook_ The pool's hook; the pool key is the one it serves.
    /// @param token The INFERA token; must be the hook's currency1.
    /// @param startTick Starting price as a tick (INFERA per ETH), a multiple of the tick spacing.
    /// @param buyer Receives the first buy's INFERA.
    /// @param minTokensOut The least INFERA the first buy may return.
    function initialize(InferaEthHook hook_, address token, int24 startTick, address buyer, uint256 minTokensOut)
        external
        payable
    {
        if (msg.sender != launcher) revert NotLauncher();
        if (initialized) revert AlreadyInitialized();
        if (msg.value == 0) revert NoInitialBuy();
        if (buyer == address(0)) revert ZeroAddress();
        PoolKey memory key = hook_.poolKey();
        if (Currency.unwrap(key.currency1) != token) revert WrongToken();
        if (startTick % key.tickSpacing != 0) revert MisalignedTick();

        initialized = true;
        hook = hook_;
        poolKey_ = key;
        tickLower = TickMath.minUsableTick(key.tickSpacing);
        tickUpper = startTick;

        // forge-lint: disable-next-line(unused-return) the returned tick is startTick
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(startTick));
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
        (uint256 ethUsed, uint256 inferaOut) = _firstBuy(key, buyer, minTokensOut);

        // Rounding the liquidity down leaves a few wei of INFERA here; it goes to buybacks.
        IInferaToken token = IInferaToken(Currency.unwrap(key.currency1));
        uint256 dust = token.balanceOf(address(this));
        // forge-lint: disable-next-line(erc20-unchecked-transfer) InferaToken reverts on failure
        if (dust != 0) token.transfer(hook.buybacksRecipient(), dust);

        // forge-lint: disable-next-line(reentrancy-events) calls above go only to the PoolManager, INFERA and the hook
        emit Launched(address(hook), address(token), tickUpper, liquidity, buyer, ethUsed, inferaOut);
        return "";
    }

    /// @dev The position sits entirely below the starting price, so it holds only INFERA:
    ///      liquidity = supply * 2^96 / (sqrtPriceUpper - sqrtPriceLower), rounded down.
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
