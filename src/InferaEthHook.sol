// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

/// @notice The launch-protection surface of the INFERA token.
interface IInferaLaunchToken {
    function initializer() external view returns (address);
    function poolManager() external view returns (address);
    function startedAt() external view returns (uint256);
    function walletTokenLimit() external view returns (uint256);
}

/// @notice The router that identifies its caller (the buyer) while it swaps.
interface ILaunchProtectionRouter {
    function msgSender() external view returns (address);
}

/// @title InferaEthHook
/// @notice Uniswap v4 hook for the native ETH / INFERA pool launched through Programmable.
///
/// Every buy and sell pays 2.3% of its gross ETH leg, in ETH:
///   - 2.0% to Infera: 1.0% team, 0.5% buybacks, 0.5% compute (rounded down), and
///   - 0.3% to Programmable's fixed platform recipient (rounded up per trade), as Programmable
///     requires of every Ethereum Mainnet launch pool. It is a constant: nobody can change or
///     disable it.
///
/// "Gross ETH leg" is the ETH a buyer pays in total, or the ETH the pool pays out on a sell before
/// fees. It holds for all four swap shapes: exact-input and exact-output, buy and sell.
///
/// Fees accrue inside this contract, fully backed by the ETH it holds, and are paid out by
/// {release}: anyone may call it, and it only ever pays the configured recipient, so fees can
/// never be stuck behind a lost owner key. Swaps never transfer ETH to recipients.
///
/// Same-block price enforcement (anti-sandwich): within a block, no swap executes at a better price
/// than the pool's price when the block opened (its first swap). Whatever a swap would have gained
/// beyond that price is withheld and goes to the buybacks recipient (ETH through the buybacks bucket,
/// INFERA directly). It never goes to liquidity providers: in-range liquidity can be added
/// just-in-time by the same trader, who would then recapture it. A same-block sandwich's front-run
/// pays at least the opening price and its back-run receives at most the opening price, so the round
/// trip cannot profit.
///
/// Limits: this is same-block price enforcement, not complete MEV protection. The block's first swap
/// sets the anchor and is never constrained (its own price impact and fees already put it below the
/// anchor). A later swap in the same block is held to the anchor when earlier swaps moved the price in
/// its favour. Attacks spread over several blocks are not covered.
///
/// Launch protection (Programmable's required rules for new Ethereum launches), counted from the
/// token's {IInferaLaunchToken.startedAt}:
///   - First 300 seconds: buys must come through the canonical Universal Router, which identifies
///     the buyer, or be the launch initializer's first buy (the developer's). Each buyer can buy at
///     most 2% of the supply in total; selling never restores it, and no buyer is exempt.
///   - First 30 seconds: buys pay an opening tax on top of the normal 2.3%, so the total buy fee
///     starts at 99% and falls linearly to 2.3%. The developer and up to six fixed wallets are exempt
///     from the opening tax only. The tax is held in this contract and payable only to Programmable.
/// A swap whose ETH side is specified (exact-input buy, exact-output sell) must fill completely;
/// a fill stopped early by the trader's price limit reverts rather than charge fees on unfilled ETH.
///
/// Owner controls (disclose for review): change the team / buybacks / compute recipients, and
/// transfer ownership (two-step). The owner cannot touch rates, Programmable's share or its
/// recipient, or accrued Programmable fees.
contract InferaEthHook is IHooks {
    using PoolIdLibrary for PoolKey;

    // ---------------------------------------------------------------- rates

    uint256 public constant BPS = 10_000;
    /// @notice Infera's share of every trade's gross ETH leg: 200 bps (2%).
    uint256 public constant INFERA_BPS = 200;
    /// @notice Programmable's platform share: 30 bps (0.3%).
    uint256 public constant PROGRAMMABLE_BPS = 30;
    /// @notice Total charged per trade: 230 bps (2.3%).
    uint256 public constant TOTAL_BPS = INFERA_BPS + PROGRAMMABLE_BPS;
    /// @notice Programmable's fixed platform recipient for new Ethereum Mainnet approvals.
    address public constant PROGRAMMABLE_RECIPIENT = 0xD88539d3c4C460136a733A3Fd60cf6BF269079da;
    /// @notice The canonical Uniswap v4 PoolManager on Ethereum Mainnet, enforced there by the constructor.
    address public constant MAINNET_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    /// @notice The canonical Universal Router on Ethereum Mainnet, and its runtime code hash.
    address public constant MAINNET_ROUTER = 0xd92A36B0000531EF3063dEd4De20A0783308446C;
    bytes32 public constant MAINNET_ROUTER_CODE_HASH =
        0x41ccd905c8e4de29ce9536ff49233b79e3085a0987d490664e703ee1e7b1dc49;

    /// @notice Buyer limits and router-only buys last this long after trading starts.
    uint256 public constant PROTECTION_SECONDS = 300;
    /// @notice The opening tax decays to zero over this long after trading starts.
    uint256 public constant DECAY_SECONDS = 30;
    /// @notice Total buy fee at the opening instant: 99%, in parts per million.
    uint256 public constant OPENING_TOTAL_PPM = 990_000;
    /// @notice The normal total buy fee in parts per million: 2.3%.
    uint256 public constant NORMAL_PPM = TOTAL_BPS * 100;
    uint256 private constant PPM = 1_000_000;

    enum Bucket {
        Team, // 1.0% of gross (half of Infera's 2%)
        Buybacks, // 0.5% of gross
        Compute, // 0.5% of gross
        Programmable // 0.3% of gross
    }

    // ---------------------------------------------------------------- state

    IPoolManager public immutable poolManager;
    address public immutable infera;
    uint24 public immutable lpFee;
    int24 public immutable tickSpacing;
    /// @notice The launch initializer; its swap is the developer's first buy.
    address public immutable initializer;
    /// @notice The developer (the launch wallet): exempt from the opening tax, not from the buy limit.
    address public immutable developer;
    /// @notice The only router buyers can use during the protection window, and its code hash.
    address public immutable router;
    bytes32 public immutable routerCodeHash;
    /// @dev Up to six more wallets exempt from the opening tax; zero entries are unused.
    address[6] private _exemptWallets;

    address public owner;
    address public pendingOwner;
    address public teamRecipient;
    address public buybacksRecipient;
    address public computeRecipient;

    /// @notice ETH accrued and not yet released, per bucket. With {openingTaxAccrued}, always sums to
    ///         this contract's balance.
    uint256[4] public accrued;
    /// @notice Lifetime trading fees collected, per bucket (fees only; see {withheldEth}).
    uint256[4] public collected;
    /// @notice Lifetime ETH paid out, per bucket.
    uint256[4] public released;
    /// @notice Lifetime ETH withheld by same-block price enforcement, booked to the buybacks bucket.
    ///         For every bucket: collected + (buybacks ? withheldEth : 0) == accrued + released.
    uint256 public withheldEth;
    /// @notice Lifetime INFERA withheld by same-block price enforcement, sent to the buybacks recipient.
    uint256 public withheldInfera;

    /// @notice Opening tax held for Programmable and not yet released. The hook's ETH balance always
    ///         equals the four buckets' `accrued` plus this.
    uint256 public openingTaxAccrued;
    /// @notice Lifetime opening tax collected, and released to Programmable.
    uint256 public openingTaxCollected;
    uint256 public openingTaxReleased;
    /// @notice INFERA each buyer has bought during the protection window.
    mapping(address buyer => uint256 amount) public boughtDuringProtection;

    /// @dev Set in beforeSwap, consumed and cleared in afterSwap of the same swap.
    address private _activeBuyer;
    uint256 private _activeTaxPpm;
    uint256 private _expectedPoolEth;

    /// @notice The pool price when the current (or last) block's first swap began.
    struct BlockStart {
        uint48 blockNumber;
        uint160 sqrtPriceX96;
    }

    /// @notice Anti-sandwich anchor: no swap can execute at a better price than this within its block.
    BlockStart public blockStart;

    uint256 private _locked = 1;
    uint256 private constant MAX_HOOK_DELTA = 2 ** 127 - 1; // type(int128).max

    /// @notice Who owns the hook and receives Infera's fees.
    struct Recipients {
        address owner;
        address team;
        address buybacks;
        address compute;
    }

    /// @notice The launch-protection parties.
    struct Protection {
        address initializer;
        address developer;
        address router;
        bytes32 routerCodeHash;
        address[6] exemptWallets;
    }

    // ---------------------------------------------------------------- events

    event FeesCharged(
        bool indexed buy, uint256 grossEth, uint256 team, uint256 buybacks, uint256 compute, uint256 programmable
    );
    event Released(Bucket indexed bucket, address indexed recipient, uint256 amount);
    /// @dev `releaseAll` skipped a bucket whose recipient rejected ETH; the ETH stays accrued.
    event ReleaseSkipped(Bucket indexed bucket, address indexed recipient, uint256 amount);
    /// @notice A swap would have beaten its block's opening price; `amount` (in ETH if `eth`, else
    ///         INFERA) was withheld for the buybacks recipient.
    event BlockStartPriceEnforced(bool indexed buy, bool eth, uint256 amount, address indexed recipient);
    event OpeningTaxCharged(address indexed buyer, uint256 grossEth, uint256 amount);
    event OpeningTaxReleased(uint256 amount);
    event RecipientUpdated(Bucket indexed bucket, address previous, address current);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ---------------------------------------------------------------- errors

    error NotPoolManager();
    error NotOwner();
    error NotPendingOwner();
    error NotBoundPool();
    error ZeroAddress();
    error WrongPoolManager();
    error HookNotImplemented();
    error ProgrammableRecipientIsFixed();
    error ReleaseFailed(Bucket bucket, address recipient, uint256 amount);
    error Reentrancy();
    error UnexpectedEther();
    error FeeOverflow();
    error InvalidConfiguration();
    error UnsupportedRouter();
    error InvalidBuyer();
    error BuyerLimitExceeded(address buyer, uint256 attempted, uint256 limit);
    error PartialFillUnsupported(uint256 expected, uint256 actual);
    error NoTrade();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    /// @param manager_ The Uniswap v4 PoolManager (Ethereum Mainnet: 0x000000000004444c5dc75cB358380D2e3dE08A90).
    /// @param infera_ The INFERA token; its initializer and PoolManager must match.
    /// @param lpFee_ The pool's static LP fee, in pips (e.g. 3000 = 0.3%).
    /// @param tickSpacing_ The pool's tick spacing.
    /// @param recipients_ The owner, passed explicitly (under CREATE2 `msg.sender` is the factory), and
    ///        the team / buybacks / compute recipients.
    /// @param protection_ The launch initializer, the developer, the router buyers must use during the
    ///        protection window (the canonical Universal Router on Mainnet) and its code hash, and up
    ///        to six more opening-tax-exempt wallets.
    constructor(
        IPoolManager manager_,
        address infera_,
        uint24 lpFee_,
        int24 tickSpacing_,
        Recipients memory recipients_,
        Protection memory protection_
    ) {
        if (
            address(manager_) == address(0) || infera_ == address(0) || recipients_.owner == address(0)
                || recipients_.team == address(0) || recipients_.buybacks == address(0)
                || recipients_.compute == address(0) || protection_.initializer == address(0)
                || protection_.developer == address(0)
        ) revert ZeroAddress();
        // On Ethereum Mainnet, only the canonical Uniswap v4 PoolManager.
        if (block.chainid == 1 && address(manager_) != MAINNET_POOL_MANAGER) revert WrongPoolManager();
        _validateProtection(manager_, infera_, protection_);
        // Reverts unless this contract's address carries exactly the permission bits below.
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());

        poolManager = manager_;
        infera = infera_;
        lpFee = lpFee_;
        tickSpacing = tickSpacing_;
        initializer = protection_.initializer;
        developer = protection_.developer;
        router = protection_.router;
        routerCodeHash = protection_.routerCodeHash;
        _exemptWallets = protection_.exemptWallets;

        owner = recipients_.owner;
        teamRecipient = recipients_.team;
        buybacksRecipient = recipients_.buybacks;
        computeRecipient = recipients_.compute;
        emit OwnershipTransferred(address(0), recipients_.owner);
        emit RecipientUpdated(Bucket.Team, address(0), recipients_.team);
        emit RecipientUpdated(Bucket.Buybacks, address(0), recipients_.buybacks);
        emit RecipientUpdated(Bucket.Compute, address(0), recipients_.compute);
    }

    function _validateProtection(IPoolManager manager_, address infera_, Protection memory p) private view {
        if (
            IInferaLaunchToken(infera_).initializer() != p.initializer
                || IInferaLaunchToken(infera_).poolManager() != address(manager_) || p.developer == infera_
                || p.developer == address(manager_) || p.router.code.length == 0
                || p.router.codehash != p.routerCodeHash
                || (block.chainid == 1 && (p.router != MAINNET_ROUTER || p.routerCodeHash != MAINNET_ROUTER_CODE_HASH))
        ) revert InvalidConfiguration();
        // forge-lint: disable-next-item(require-revert-in-loop) constructor configuration check over six slots
        for (uint256 i = 0; i < 6; ++i) {
            address wallet = p.exemptWallets[i];
            if (wallet == address(0)) continue;
            if (
                wallet == p.developer || wallet == address(this) || wallet == infera_ || wallet == address(manager_)
                    || wallet == p.router || wallet == p.initializer
            ) revert InvalidConfiguration();
            for (uint256 j = 0; j < i; ++j) {
                if (wallet == p.exemptWallets[j]) revert InvalidConfiguration();
            }
        }
    }

    /// @notice The id of the only pool this hook serves. Computed rather than stored, so every value
    ///         in the deployed code is known before the hook's CREATE2 address is chosen.
    function poolId() external view returns (PoolId) {
        return poolKey().toId();
    }

    /// @notice The pool key this hook serves.
    function poolKey() public view returns (PoolKey memory) {
        return PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(infera),
            fee: lpFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(this))
        });
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------- fee quotes

    /// @notice Fees for a trade whose gross ETH leg is `gross`.
    function quoteFromGross(uint256 gross) public pure returns (uint256[4] memory fees) {
        uint256 inferaFee = gross * INFERA_BPS / BPS;
        uint256 programmableFee = _ceilDiv(gross * PROGRAMMABLE_BPS, BPS);
        // Dust: never charge more than the leg itself.
        if (inferaFee + programmableFee > gross) programmableFee = gross - inferaFee;
        fees = _split(inferaFee, programmableFee);
    }

    /// @notice Fees for a trade whose ETH leg *excluding* fees is `net` (exact-output buys and sells):
    ///         the gross leg is `net + fees`, and the fees are 2.3% of that gross leg.
    function quoteFromNet(uint256 net) public pure returns (uint256[4] memory fees, uint256 gross) {
        gross = _ceilDiv(net * BPS, BPS - TOTAL_BPS);
        uint256 total = gross - net;
        uint256 programmableFee = _ceilDiv(gross * PROGRAMMABLE_BPS, BPS);
        if (programmableFee > total) programmableFee = total;
        fees = _split(total - programmableFee, programmableFee);
    }

    /// @notice Fees for a buy that also pays an opening tax of `taxPpm` (parts per million of its gross
    ///         ETH leg). With `amountIsNet` the amount excludes all fees (exact-output buys). With no
    ///         tax this is exactly {quoteFromGross} / {quoteFromNet}.
    function quoteBuy(uint256 amount, bool amountIsNet, uint256 taxPpm)
        public
        pure
        returns (uint256[4] memory fees, uint256 openingTax, uint256 gross)
    {
        if (taxPpm == 0) {
            if (amountIsNet) (fees, gross) = quoteFromNet(amount);
            else (fees, gross) = (quoteFromGross(amount), amount);
            return (fees, 0, gross);
        }
        uint256 totalPpm = NORMAL_PPM + taxPpm; // at most OPENING_TOTAL_PPM, below 100%
        uint256 total;
        if (amountIsNet) {
            gross = FullMath.mulDivRoundingUp(amount, PPM, PPM - totalPpm);
            total = gross - amount;
        } else {
            gross = amount;
            total = FullMath.mulDivRoundingUp(gross, totalPpm, PPM);
            if (total > gross) total = gross;
        }
        // The normal fees come first, at their usual rates; the opening tax is the rest.
        uint256 programmableFee = _ceilDiv(gross * PROGRAMMABLE_BPS, BPS);
        if (programmableFee > total) programmableFee = total;
        uint256 inferaFee = gross * INFERA_BPS / BPS;
        if (inferaFee > total - programmableFee) inferaFee = total - programmableFee;
        fees = _split(inferaFee, programmableFee);
        openingTax = total - programmableFee - inferaFee;
    }

    /// @notice The opening tax, in parts per million, a buy by `buyer` pays right now.
    function openingTaxPpm(address buyer) public view returns (uint256) {
        uint256 startedAt = IInferaLaunchToken(infera).startedAt();
        // forge-lint: disable-next-line(block-timestamp) the opening tax decays over seconds, as Programmable requires
        if (startedAt == 0 || block.timestamp >= startedAt + DECAY_SECONDS || isOpeningTaxExempt(buyer)) return 0;
        return
            FullMath.mulDiv(OPENING_TOTAL_PPM - NORMAL_PPM, startedAt + DECAY_SECONDS - block.timestamp, DECAY_SECONDS);
    }

    /// @notice Whether `wallet` is exempt from the opening tax (the developer and the six fixed wallets).
    function isOpeningTaxExempt(address wallet) public view returns (bool) {
        if (wallet == address(0)) return false;
        if (wallet == developer) return true;
        for (uint256 i = 0; i < 6; ++i) {
            if (wallet == _exemptWallets[i]) return true;
        }
        return false;
    }

    /// @notice The up to six wallets exempt from the opening tax besides the developer.
    function exemptWallets() external view returns (address[6] memory) {
        return _exemptWallets;
    }

    /// @notice Whether buyer limits and router-only buys are in force.
    function protectionActive() public view returns (bool) {
        uint256 startedAt = IInferaLaunchToken(infera).startedAt();
        // forge-lint: disable-next-line(block-timestamp) the protection window is defined in seconds
        return startedAt != 0 && block.timestamp < startedAt + PROTECTION_SECONDS;
    }

    function _split(uint256 inferaFee, uint256 programmableFee) private pure returns (uint256[4] memory fees) {
        fees[uint256(Bucket.Team)] = inferaFee / 2; // 100 of 200 bps
        fees[uint256(Bucket.Buybacks)] = inferaFee / 4; // 50 of 200 bps
        fees[uint256(Bucket.Compute)] = inferaFee - fees[0] - fees[1]; // remainder, so the split is exact
        fees[uint256(Bucket.Programmable)] = programmableFee;
    }

    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    // ---------------------------------------------------------------- swap callbacks

    /// @dev Anchors the block-start price, then, when ETH is the specified currency (exact-input
    ///      buy, exact-output sell), charges the fees by returning a positive specified delta.
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (params.amountSpecified == 0) revert NoTrade();
        // The only pool this hook serves: native ETH (currency0) / INFERA (currency1) at this fee and spacing.
        if (
            !key.currency0.isAddressZero() || Currency.unwrap(key.currency1) != infera || key.fee != lpFee
                || key.tickSpacing != tickSpacing || address(key.hooks) != address(this)
        ) revert NotBoundPool();
        _anchorBlockStartPrice(key.toId());
        if (params.zeroForOne) _identifyBuyer(sender);
        if (!_ethIsSpecified(params)) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        uint256 total;
        if (params.amountSpecified < 0) {
            // Exact-input buy: the trader pays exactly |amountSpecified| ETH, which is the gross leg.
            // forge-lint: disable-next-line(unsafe-typecast) amountSpecified < 0, so the negation is positive
            uint256 gross = uint256(-params.amountSpecified);
            (uint256[4] memory fees, uint256 openingTax,) = quoteBuy(gross, false, _activeTaxPpm);
            total = _accrueFees(true, gross, fees) + _accrueOpeningTax(_activeBuyer, gross, openingTax);
            if (total >= gross) revert NoTrade();
            _expectedPoolEth = gross - total;
        } else {
            // Exact-output sell: the trader receives exactly amountSpecified ETH; the pool pays out the fees on top.
            // forge-lint: disable-next-line(unsafe-typecast) amountSpecified >= 0 in this branch
            (uint256[4] memory fees, uint256 gross) = quoteFromNet(uint256(params.amountSpecified));
            total = _accrueFees(false, gross, fees);
            _expectedPoolEth = gross;
        }
        _takeEth(total);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(_toInt128(total), 0), 0);
    }

    /// @dev Holds the swap to the block-start price (see {blockStart}), then, when ETH is the
    ///      unspecified currency (exact-input sell, exact-output buy), charges the fees. Both are
    ///      returned as a positive unspecified delta. `delta` is the pool's own swap delta, seen from
    ///      the trader's side: negative amounts are paid in, positive amounts are received.
    function afterSwap(address, PoolKey calldata, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        // beforeSwap already rejected any other pool for this swap and anchored the price.
        if (_ethIsSpecified(params)) {
            uint256 poolEth = params.zeroForOne ? _paidIn(delta.amount0()) : _received(delta.amount0());
            if (poolEth != _expectedPoolEth) revert PartialFillUnsupported(_expectedPoolEth, poolEth);
        }
        // Clear this swap's state before any external call.
        address buyer = _activeBuyer;
        uint256 taxPpm = _activeTaxPpm;
        _activeBuyer = address(0);
        _activeTaxPpm = 0;
        _expectedPoolEth = 0;

        uint256 unspecifiedTake;
        if (params.zeroForOne) {
            (uint256 take, uint256 bought, bool takeIsEth) = _afterBuy(params.amountSpecified < 0, delta, buyer, taxPpm);
            _countPurchase(buyer, bought);
            if (takeIsEth) _takeEth(take);
            else _sendWithheldInfera(take);
            unspecifiedTake = take;
        } else {
            unspecifiedTake = _afterSell(params.amountSpecified < 0, delta);
        }
        return (IHooks.afterSwap.selector, _toInt128(unspecifiedTake));
    }

    // ---------------------------------------------------------------- launch protection

    /// @dev For a buy: during the protection window, works out who is buying (the developer for the
    ///      initializer's first buy, otherwise the canonical router's caller) and records them for
    ///      the 2% limit; during the first 30 seconds, also the opening tax they pay.
    function _identifyBuyer(address sender) private {
        if (!protectionActive()) return;
        address buyer;
        if (sender == initializer) {
            buyer = developer;
        } else {
            if (sender != router || sender.codehash != routerCodeHash) revert UnsupportedRouter();
            buyer = ILaunchProtectionRouter(sender).msgSender();
            if (buyer == address(0) || buyer == router || buyer == address(this) || buyer == address(poolManager)) {
                revert InvalidBuyer();
            }
        }
        _activeBuyer = buyer;
        _activeTaxPpm = openingTaxPpm(buyer);
    }

    /// @dev Adds a buy to its buyer's protection-window total; reverts the swap past 2% of supply.
    function _countPurchase(address buyer, uint256 bought) private {
        if (buyer == address(0)) return;
        uint256 total = boughtDuringProtection[buyer] + bought;
        uint256 limit = IInferaLaunchToken(infera).walletTokenLimit();
        if (total > limit) revert BuyerLimitExceeded(buyer, total, limit);
        boughtDuringProtection[buyer] = total;
    }

    /// @dev Books an opening tax for Programmable. State only; the ETH is taken with the fees.
    function _accrueOpeningTax(address buyer, uint256 gross, uint256 amount) private returns (uint256) {
        if (amount == 0) return 0;
        openingTaxAccrued += amount;
        openingTaxCollected += amount;
        emit OpeningTaxCharged(buyer, gross, amount);
        return amount;
    }

    /// @dev Buy: ETH in, INFERA out. Returns what the hook takes of the unspecified currency.
    ///      Also returns the INFERA the buyer actually receives. State only: the caller moves `take`
    ///      (ETH taken into the hook, or withheld INFERA sent to buybacks) after counting the purchase.
    function _afterBuy(bool exactInput, BalanceDelta delta, address buyer, uint256 taxPpm)
        private
        returns (uint256 take, uint256 bought, bool takeIsEth)
    {
        uint256 ethIn = _paidIn(delta.amount0());
        uint256 inferaOut = _received(delta.amount1());
        if (inferaOut == 0) revert NoTrade();
        if (exactInput) {
            // INFERA out is unspecified: no more than ethIn buys at the block-start price.
            uint256 maxOut = _inferaWorth(ethIn, blockStart.sqrtPriceX96, true);
            take = inferaOut > maxOut ? inferaOut - maxOut : 0;
            _bookExcess(true, false, take);
            bought = inferaOut - take;
        } else {
            // ETH in is unspecified: pay at least what inferaOut cost at the block-start price,
            // and the fees (and any opening tax) on top of that.
            uint256 minCost = _ethWorth(inferaOut, blockStart.sqrtPriceX96, false);
            uint256 excess = minCost > ethIn ? minCost - ethIn : 0;
            (uint256[4] memory fees, uint256 openingTax, uint256 gross) = quoteBuy(ethIn + excess, true, taxPpm);
            _bookExcess(true, true, excess);
            take = excess + _accrueFees(true, gross, fees) + _accrueOpeningTax(buyer, gross, openingTax);
            bought = inferaOut;
            takeIsEth = true;
        }
    }

    /// @dev Sell: INFERA in, ETH out. Returns what the hook takes of the unspecified currency.
    function _afterSell(bool exactInput, BalanceDelta delta) private returns (uint256 take) {
        uint256 inferaIn = _paidIn(delta.amount1());
        uint256 ethOut = _received(delta.amount0());
        if (exactInput) {
            // ETH out is unspecified: no more than inferaIn is worth at the block-start price, and
            // the fees come out of that.
            uint256 maxOut = _ethWorth(inferaIn, blockStart.sqrtPriceX96, true);
            uint256 gross = ethOut > maxOut ? maxOut : ethOut;
            uint256 excess = ethOut - gross;
            _bookExcess(false, true, excess);
            uint256 total = _accrueFees(false, gross, quoteFromGross(gross));
            take = excess + total;
            _takeEth(take);
        } else {
            // INFERA in is unspecified: pay at least what ethOut (fees included) cost at the
            // block-start price.
            uint256 minIn = _inferaWorth(ethOut, blockStart.sqrtPriceX96, false);
            take = minIn > inferaIn ? minIn - inferaIn : 0;
            _bookExcess(false, false, take);
            _sendWithheldInfera(take);
        }
    }

    // ---------------------------------------------------------------- anti-sandwich

    /// @dev Records the pool price on the block's first swap. Nothing else in a block moves the
    ///      price (liquidity changes and donations do not), so this is the price the block opened at.
    function _anchorBlockStartPrice(PoolId id) private {
        if (blockStart.blockNumber == block.number) return;
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, id);
        // forge-lint: disable-next-line(unsafe-typecast) block numbers fit in 48 bits
        blockStart = BlockStart({blockNumber: uint48(block.number), sqrtPriceX96: sqrtPriceX96});
    }

    /// @dev Books the part of a swap that beat the block-start price. ETH accrues to the buybacks
    ///      bucket (taken with the fees); INFERA is sent to the buybacks recipient by
    ///      {_sendWithheldInfera}. State only.
    function _bookExcess(bool buy, bool eth, uint256 amount) private {
        if (amount == 0) return;
        if (eth) {
            accrued[uint256(Bucket.Buybacks)] += amount;
            withheldEth += amount;
        } else {
            withheldInfera += amount;
        }
        emit BlockStartPriceEnforced(buy, eth, amount, buybacksRecipient);
    }

    /// @dev The hook returns the same amount as its swap delta, so its PoolManager balance nets to zero.
    function _sendWithheldInfera(uint256 amount) private {
        if (amount != 0) poolManager.take(Currency.wrap(infera), buybacksRecipient, amount);
    }

    /// @dev INFERA worth `ethAmount` at `sqrtPriceX96` (INFERA per ETH = (sqrtPriceX96 / 2^96)^2).
    function _inferaWorth(uint256 ethAmount, uint160 sqrtPriceX96, bool roundUp) private pure returns (uint256) {
        if (roundUp) {
            return FullMath.mulDivRoundingUp(
                FullMath.mulDivRoundingUp(ethAmount, sqrtPriceX96, FixedPoint96.Q96), sqrtPriceX96, FixedPoint96.Q96
            );
        }
        return
            FullMath.mulDiv(FullMath.mulDiv(ethAmount, sqrtPriceX96, FixedPoint96.Q96), sqrtPriceX96, FixedPoint96.Q96);
    }

    /// @dev ETH worth `inferaAmount` at `sqrtPriceX96`.
    function _ethWorth(uint256 inferaAmount, uint160 sqrtPriceX96, bool roundUp) private pure returns (uint256) {
        if (roundUp) {
            return FullMath.mulDivRoundingUp(
                FullMath.mulDivRoundingUp(inferaAmount, FixedPoint96.Q96, sqrtPriceX96), FixedPoint96.Q96, sqrtPriceX96
            );
        }
        return
            FullMath.mulDiv(
                FullMath.mulDiv(inferaAmount, FixedPoint96.Q96, sqrtPriceX96), FixedPoint96.Q96, sqrtPriceX96
            );
    }

    function _paidIn(int128 amount) private pure returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast) only cast when amount < 0; int256 holds -int128.min
        return amount < 0 ? uint256(-int256(amount)) : 0;
    }

    function _received(int128 amount) private pure returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast) only cast when amount > 0
        return amount > 0 ? uint256(int256(amount)) : 0;
    }

    /// @dev currency0 (ETH) is the specified currency when exact-input and zeroForOne agree.
    function _ethIsSpecified(SwapParams calldata params) private pure returns (bool) {
        return (params.amountSpecified < 0) == params.zeroForOne;
    }

    /// @dev Books a trade's fees. State only; the ETH is taken by {_takeEth}.
    function _accrueFees(bool buy, uint256 gross, uint256[4] memory fees) private returns (uint256 total) {
        total = fees[0] + fees[1] + fees[2] + fees[3];
        if (total == 0) return 0;
        for (uint256 i = 0; i < 4; ++i) {
            accrued[i] += fees[i];
            collected[i] += fees[i];
        }
        emit FeesCharged(buy, gross, fees[0], fees[1], fees[2], fees[3]);
    }

    /// @dev Takes ETH the hook is owed from the PoolManager into this contract.
    function _takeEth(uint256 amount) private {
        if (amount != 0) poolManager.take(CurrencyLibrary.ADDRESS_ZERO, address(this), amount);
    }

    function _toInt128(uint256 x) private pure returns (int128) {
        if (x > MAX_HOOK_DELTA) revert FeeOverflow();
        // forge-lint: disable-next-line(unsafe-typecast) bounded by int128.max on the line above
        return int128(int256(x));
    }

    // ---------------------------------------------------------------- payouts

    /// @notice The address a bucket pays out to.
    function recipientOf(Bucket bucket) public view returns (address) {
        if (bucket == Bucket.Team) return teamRecipient;
        if (bucket == Bucket.Buybacks) return buybacksRecipient;
        if (bucket == Bucket.Compute) return computeRecipient;
        return PROGRAMMABLE_RECIPIENT;
    }

    /// @notice Pays a bucket's accrued ETH to its recipient. Callable by anyone. Reverts, keeping
    ///         the ETH accrued, if the recipient rejects it.
    function release(Bucket bucket) external nonReentrant returns (uint256 amount) {
        address recipient;
        bool ok;
        (amount, recipient, ok) = _release(bucket);
        if (!ok) revert ReleaseFailed(bucket, recipient, amount);
        // forge-lint: disable-next-line(reentrancy-events) emitted under the lock, after the outcome is known
        if (amount != 0) emit Released(bucket, recipient, amount);
    }

    /// @notice Pays the held opening tax to Programmable's fixed treasury. Callable by anyone.
    function releaseOpeningTax() external nonReentrant returns (uint256 amount) {
        amount = _releaseOpeningTax();
    }

    /// @dev Effects before the transfer; reverts (keeping the tax held) if the treasury rejects ETH.
    function _releaseOpeningTax() private returns (uint256 amount) {
        amount = openingTaxAccrued;
        if (amount == 0) return 0;
        openingTaxAccrued = 0;
        openingTaxReleased += amount;
        emit OpeningTaxReleased(amount);
        // forge-lint: disable-next-line(arbitrary-send-eth, reentrancy-eth) fixed Programmable treasury; callers hold the lock
        (bool ok,) = PROGRAMMABLE_RECIPIENT.call{value: amount}("");
        if (!ok) revert ReleaseFailed(Bucket.Programmable, PROGRAMMABLE_RECIPIENT, amount);
    }

    /// @notice Pays every bucket and the held opening tax. Callable by anyone. A recipient that
    ///         rejects ETH only holds up its own bucket (`ReleaseSkipped`); the others are still paid.
    function releaseAll() external nonReentrant {
        _releaseOpeningTax();
        for (uint256 i = 0; i < 4; ++i) {
            (uint256 amount, address recipient, bool ok) = _release(Bucket(i));
            if (amount == 0) continue;
            // Emitted under the lock, once the transfer's outcome is known.
            if (ok) {
                // forge-lint: disable-next-line(reentrancy-events)
                emit Released(Bucket(i), recipient, amount);
            } else {
                // forge-lint: disable-next-line(reentrancy-events)
                emit ReleaseSkipped(Bucket(i), recipient, amount);
            }
        }
    }

    /// @dev Zeroes the bucket before the transfer; a failed transfer restores it. Recipients are the
    ///      owner-set Infera addresses or Programmable's fixed address, and callers hold the lock.
    function _release(Bucket bucket) private returns (uint256 amount, address recipient, bool ok) {
        amount = accrued[uint256(bucket)];
        recipient = recipientOf(bucket);
        ok = amount == 0;
        if (ok) return (amount, recipient, ok);
        accrued[uint256(bucket)] = 0;
        released[uint256(bucket)] += amount;
        // forge-lint: disable-next-line(arbitrary-send-eth, reentrancy-eth, calls-loop)
        (ok,) = recipient.call{value: amount}("");
        if (!ok) {
            accrued[uint256(bucket)] = amount;
            released[uint256(bucket)] -= amount;
        }
    }

    // ---------------------------------------------------------------- owner controls

    /// @notice Changes the team, buybacks or compute recipient. Accrued, unreleased ETH in that
    ///         bucket goes to the new recipient on the next release. Programmable's is fixed.
    function setRecipient(Bucket bucket, address recipient) external onlyOwner {
        if (bucket == Bucket.Programmable) revert ProgrammableRecipientIsFixed();
        if (recipient == address(0)) revert ZeroAddress();
        address previous = recipientOf(bucket);
        if (bucket == Bucket.Team) teamRecipient = recipient;
        else if (bucket == Bucket.Buybacks) buybacksRecipient = recipient;
        else computeRecipient = recipient;
        emit RecipientUpdated(bucket, previous, recipient);
    }

    /// @notice Starts an ownership transfer; `address(0)` cancels a pending one.
    // forge-lint: disable-next-line(missing-zero-check)
    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address previous = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(previous, msg.sender);
    }

    /// @dev Only the PoolManager sends ETH here (via `take`).
    receive() external payable {
        if (msg.sender != address(poolManager)) revert UnexpectedEther();
    }

    // ---------------------------------------------------------------- unused callbacks

    function beforeInitialize(address, PoolKey calldata, uint160) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}
