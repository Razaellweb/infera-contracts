// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {InferaEthHook} from "../src/InferaEthHook.sol";
import {InferaEthConfig} from "../src/InferaEthConfig.sol";
import {InferaToken} from "../src/InferaToken.sol";
import {InferaLaunchInitializer} from "../src/InferaLaunchInitializer.sol";

/// The full launch on a real v4 PoolManager: token minted to the initializer, the hook bound to it,
/// and the initializer opening the pool the way Programmable's graph factory calls it.
contract InferaLaunchTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    uint256 constant SUPPLY = 1_000_000_000 ether;
    int24 constant START_TICK = 187_320; // ~136.4M INFERA per ETH: about USD 15,087 FDV at USD 2,057.77/ETH
    uint256 constant FIRST_BUY = 4_859_637_193_736_836; // USD 10 at USD 2,057.77/ETH
    uint256 constant ETH_USD_8DP = 205_776_678_409; // Chainlink ETH/USD on 2026-11-11

    address launcher = makeAddr("graphFactory");
    address launchWallet = makeAddr("launchWallet");
    address team = makeAddr("team");
    address buybacks = makeAddr("buybacks");
    address compute = makeAddr("compute");

    InferaLaunchInitializer initializer;
    InferaToken token;
    InferaEthHook hook;

    function setUp() public {
        deployFreshManagerAndRouters();
        initializer = new InferaLaunchInitializer(manager, launcher);
        token = new InferaToken("Infera", "INFERA", SUPPLY, address(initializer));
        address at = address(uint160(InferaEthConfig.HOOK_FLAGS) | (uint160(0x4444) << 144));
        deployCodeTo(
            "InferaEthHook.sol:InferaEthHook",
            abi.encode(manager, address(token), uint24(3000), int24(60), launchWallet, team, buybacks, compute),
            at
        );
        hook = InferaEthHook(payable(at));
        key = hook.poolKey();
        vm.deal(launcher, 1 ether);
        // Exact-input buy fees are taken from the PoolManager's ETH before the buyer settles. The
        // Mainnet PoolManager holds about 55,000 ETH; a fresh local one holds none.
        vm.deal(address(manager), 55_000 ether);
    }

    function _launch(uint256 minOut) internal {
        vm.prank(launcher);
        initializer.initialize{value: FIRST_BUY}(hook, address(token), START_TICK, launchWallet, minOut);
    }

    function _positionLiquidity() internal view returns (uint128) {
        bytes32 positionId =
            Position.calculatePositionKey(address(initializer), initializer.tickLower(), initializer.tickUpper(), 0);
        return StateLibrary.getPositionLiquidity(manager, key.toId(), positionId);
    }

    function _trader(string memory name) internal returns (address t) {
        t = makeAddr(name);
        vm.deal(t, 100 ether);
        vm.prank(t);
        token.approve(address(swapRouter), type(uint256).max);
    }

    function _swap(address trader, bool buy, int256 amountSpecified) internal {
        vm.prank(trader);
        swapRouter.swap{value: buy ? uint256(-amountSpecified) : 0}(
            key,
            SwapParams({
                zeroForOne: buy,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    function _assertHookBacked() internal view {
        uint256 owed;
        for (uint256 i; i < 4; ++i) {
            owed += hook.accrued(i);
        }
        assertEq(address(hook).balance, owed);
        assertEq(token.balanceOf(address(hook)), 0);
    }

    // ------------------------------------------------------------ the launch

    function test_launchSeedsAndLocksTheWholeSupplyAndMakesTheFirstBuy() public {
        _launch(600_000 ether);

        assertTrue(initializer.initialized());
        uint128 locked = initializer.lockedLiquidity();
        assertGt(locked, 0);
        assertEq(_positionLiquidity(), locked, "the initializer owns the whole position");
        assertEq(initializer.tickUpper(), START_TICK);
        assertEq(initializer.tickLower(), TickMath.minUsableTick(60));

        uint256 bought = token.balanceOf(launchWallet);
        assertGt(bought, 600_000 ether, "the USD 10 buy returns about 0.065% of supply");
        assertLt(bought, 650_000 ether);
        assertEq(token.balanceOf(address(initializer)), 0, "nothing is left in the initializer");
        assertLt(token.balanceOf(buybacks), 1e9, "only rounding dust goes to buybacks");
        assertEq(
            token.balanceOf(address(manager)) + bought + token.balanceOf(buybacks),
            SUPPLY,
            "every token is accounted for"
        );

        // The first buy pays the hook's fees like any other: 2% to Infera, 0.3% to Programmable.
        assertEq(hook.accrued(3), (FIRST_BUY * 30 + 9_999) / 10_000, "Programmable's 0.3%, rounded up");
        assertApproxEqAbs(hook.accrued(0) + hook.accrued(1) + hook.accrued(2), FIRST_BUY * 200 / 10_000, 1);
        _assertHookBacked();
    }

    function test_openingValuationIsAtLeastUsd15k() public pure {
        // FDV in ETH = supply / (INFERA per ETH) = supply * 2^192 / sqrtPrice^2
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(START_TICK);
        uint256 fdvEth = FullMath.mulDiv(FullMath.mulDiv(SUPPLY, 1 << 96, sqrtPrice), 1 << 96, sqrtPrice);
        uint256 fdvUsd = fdvEth * ETH_USD_8DP / 1e8;
        assertGe(fdvUsd, 15_000 ether);
        assertLe(fdvUsd, 15_200 ether);
    }

    function test_onlyTheLauncherInitializes_andOnlyOnce() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(InferaLaunchInitializer.NotLauncher.selector);
        initializer.initialize{value: FIRST_BUY}(hook, address(token), START_TICK, launchWallet, 0);

        _launch(0);
        vm.prank(launcher);
        vm.expectRevert(InferaLaunchInitializer.AlreadyInitialized.selector);
        initializer.initialize{value: FIRST_BUY}(hook, address(token), START_TICK, launchWallet, 0);
    }

    function test_rejectsAWrongTokenAMisalignedTickOrNoFirstBuy() public {
        vm.startPrank(launcher);
        vm.expectRevert(InferaLaunchInitializer.WrongToken.selector);
        initializer.initialize{value: FIRST_BUY}(hook, makeAddr("other"), START_TICK, launchWallet, 0);
        vm.expectRevert(InferaLaunchInitializer.MisalignedTick.selector);
        initializer.initialize{value: FIRST_BUY}(hook, address(token), START_TICK + 1, launchWallet, 0);
        vm.expectRevert(InferaLaunchInitializer.NoInitialBuy.selector);
        initializer.initialize(hook, address(token), START_TICK, launchWallet, 0);
        vm.stopPrank();
    }

    function test_aFirstBuyBelowItsMinimumRevertsTheWholeLaunch() public {
        vm.prank(launcher);
        vm.expectRevert();
        initializer.initialize{value: FIRST_BUY}(hook, address(token), START_TICK, launchWallet, 10_000_000 ether);
        assertFalse(initializer.initialized(), "nothing happened");
        assertEq(token.balanceOf(address(initializer)), SUPPLY);
    }

    // ------------------------------------------------------------ after the launch

    function test_afterLaunchTradersBuyAndSell() public {
        _launch(0);
        address trader = _trader("trader");
        vm.roll(block.number + 1);
        _swap(trader, true, -1 ether);
        uint256 bought = token.balanceOf(trader);
        assertGt(bought, 0);
        vm.roll(block.number + 1);
        uint256 ethBefore = trader.balance;
        _swap(trader, false, -int256(bought));
        assertGt(trader.balance, ethBefore, "sold back for ETH");
        assertEq(_positionLiquidity(), initializer.lockedLiquidity(), "the locked liquidity never changes");
        _assertHookBacked();
    }

    function test_anyoneCanCollectPoolFeesToBuybacks_andTheLiquidityStaysLocked() public {
        _launch(0);
        address trader = _trader("trader");
        vm.roll(block.number + 1);
        _swap(trader, true, -2 ether);
        vm.roll(block.number + 1);
        _swap(trader, false, -int256(token.balanceOf(trader) / 2));

        uint256 ethBefore = buybacks.balance;
        uint256 inferaBefore = token.balanceOf(buybacks);
        vm.prank(makeAddr("anyone"));
        (uint256 eth, uint256 infera) = initializer.collectPoolFees();

        assertGt(eth, 0, "the buys earned the pool's 0.3% LP fee in ETH");
        assertGt(infera, 0, "the sell earned it in INFERA");
        assertEq(buybacks.balance - ethBefore, eth);
        assertEq(token.balanceOf(buybacks) - inferaBefore, infera);
        assertEq(_positionLiquidity(), initializer.lockedLiquidity(), "collecting never removes liquidity");
        (eth, infera) = initializer.collectPoolFees();
        assertEq(eth + infera, 0, "nothing is collected twice");
    }

    function test_poolFeesFollowTheHooksBuybacksRecipient() public {
        _launch(0);
        address trader = _trader("trader");
        vm.roll(block.number + 1);
        _swap(trader, true, -1 ether);
        address newBuybacks = makeAddr("newBuybacks");
        vm.prank(launchWallet); // the hook owner
        hook.setRecipient(InferaEthHook.Bucket.Buybacks, newBuybacks);
        initializer.collectPoolFees();
        assertGt(newBuybacks.balance, 0);
    }

    function test_theLockedPositionCannotBeWithdrawnByAnyoneElse() public {
        _launch(0);
        // A position belongs to whoever called modifyLiquidity; nobody but the initializer can touch
        // its position, and the initializer has no function that removes liquidity.
        ModifyLiquidityParams memory removeAll = ModifyLiquidityParams({
            tickLower: initializer.tickLower(),
            tickUpper: initializer.tickUpper(),
            liquidityDelta: -int256(uint256(initializer.lockedLiquidity())),
            salt: 0
        });
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(key, removeAll, ZERO_BYTES);
        assertEq(_positionLiquidity(), initializer.lockedLiquidity());
    }

    function test_collectingBeforeTheLaunchReverts() public {
        vm.expectRevert(InferaLaunchInitializer.NotInitialized.selector);
        initializer.collectPoolFees();
    }

    function test_onlyThePoolManagerCanCallTheUnlockCallback() public {
        vm.expectRevert(InferaLaunchInitializer.NotPoolManager.selector);
        initializer.unlockCallback(abi.encode(InferaLaunchInitializer.Action.Collect, address(0), uint256(0)));
    }
}
