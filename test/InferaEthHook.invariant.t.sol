// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {InferaEthHook} from "../src/InferaEthHook.sol";
import {InferaEthConfig} from "../src/InferaEthConfig.sol";
import {InferaToken} from "../src/InferaToken.sol";
import {InferaLaunchInitializer, IEthUsdFeed} from "../src/InferaLaunchInitializer.sol";
import {HookArgs, MockEthUsdFeed, ProtectedRouterMock} from "./utils/LaunchFixtures.sol";

/// Random actions against the real pool after launch protection: all four swap shapes, new blocks,
/// just-in-time liquidity, payouts and recipient changes. Reverting actions (e.g. an exact-output
/// larger than the pool) are caught, so every sequence keeps going.
contract HookHandler is Test {
    using PoolIdLibrary for PoolKey;

    IPoolManager internal immutable manager;
    PoolSwapTest internal immutable swapRouter;
    PoolModifyLiquidityTest internal immutable lpRouter;
    InferaToken internal immutable token;
    InferaEthHook internal immutable hook;
    address internal immutable owner;
    PoolKey internal key;

    int24 internal jitLower;
    int128 internal jitLiquidity;
    uint256 public swaps;

    constructor(
        IPoolManager manager_,
        PoolSwapTest swapRouter_,
        PoolModifyLiquidityTest lpRouter_,
        InferaToken token_,
        InferaEthHook hook_,
        address owner_
    ) {
        manager = manager_;
        swapRouter = swapRouter_;
        lpRouter = lpRouter_;
        token = token_;
        hook = hook_;
        owner = owner_;
        key = hook_.poolKey();
        token_.approve(address(swapRouter_), type(uint256).max);
        token_.approve(address(lpRouter_), type(uint256).max);
    }

    receive() external payable {}

    function buyExactIn(uint256 amount) external {
        _swap(true, -int256(bound(amount, 1, 50 ether)));
    }

    function sellExactIn(uint256 amount) external {
        _swap(false, -int256(bound(amount, 1, 50 ether)));
    }

    function buyExactOut(uint256 amount) external {
        _swap(true, int256(bound(amount, 1, 50 ether)));
    }

    function sellExactOut(uint256 amount) external {
        _swap(false, int256(bound(amount, 1, 50 ether)));
    }

    function nextBlock(uint256 blocks) external {
        vm.roll(block.number + bound(blocks, 1, 3));
    }

    function addJitLiquidity(uint256 liquidity) external {
        if (jitLiquidity != 0) return;
        (, int24 tick,,) = StateLibrary.getSlot0(manager, key.toId());
        int24 lower = (tick / 60) * 60 - 600;
        int128 amount = int128(int256(bound(liquidity, 1 ether, 5_000 ether)));
        try lpRouter.modifyLiquidity{value: 20_000 ether}(
            key,
            ModifyLiquidityParams({tickLower: lower, tickUpper: lower + 1200, liquidityDelta: amount, salt: "jit"}),
            ""
        ) {
            jitLower = lower;
            jitLiquidity = amount;
        } catch {}
    }

    function removeJitLiquidity() external {
        if (jitLiquidity == 0) return;
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: jitLower, tickUpper: jitLower + 1200, liquidityDelta: -jitLiquidity, salt: "jit"
            }),
            ""
        );
        jitLiquidity = 0;
    }

    function releaseAll() external {
        hook.releaseAll();
    }

    function changeRecipient(uint256 seed) external {
        address next = address(uint160(uint256(keccak256(abi.encode(seed)))));
        vm.prank(owner);
        hook.setRecipient(InferaEthHook.Bucket(seed % 3), next);
    }

    function _swap(bool buy, int256 amountSpecified) internal {
        try swapRouter.swap{value: buy ? 200 ether : 0}(
            key,
            SwapParams({
                zeroForOne: buy,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {
            ++swaps;
        } catch {}
    }
}

contract InferaEthHookInvariantTest is Test, Deployers {
    InferaEthHook hook;
    HookHandler handler;

    function setUp() public {
        deployFreshManagerAndRouters();
        ProtectedRouterMock protectedRouter = new ProtectedRouterMock(manager);
        // This test contract plays the launch initializer: it seeds the pool, then starts trading.
        InferaToken token = new InferaToken("Infera", "INFERA", 1e30, address(this), address(manager));
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.deal(address(this), 10_000 ether);

        address at = address(uint160(InferaEthConfig.HOOK_FLAGS) | (uint160(0x4444) << 144));
        deployCodeTo(
            "InferaEthHook.sol:InferaEthHook",
            HookArgs.encode(
                manager,
                address(token),
                3000,
                60,
                makeAddr("owner"),
                [makeAddr("team"), makeAddr("buybacks"), makeAddr("compute")],
                address(this),
                makeAddr("developer"),
                address(protectedRouter)
            ),
            at
        );
        hook = InferaEthHook(payable(at));
        PoolKey memory key = hook.poolKey();
        manager.initialize(key, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity{value: 1_000 ether}(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 500 ether,
                salt: 0
            }),
            ZERO_BYTES
        );
        token.start();
        vm.warp(block.timestamp + 300); // past launch protection: normal trading

        handler = new HookHandler(manager, swapRouter, modifyLiquidityRouter, token, hook, makeAddr("owner"));
        vm.deal(address(handler), 1_000_000 ether);
        token.transfer(address(handler), 1_000_000 ether);
        targetContract(address(handler));
    }

    function _sumAccrued() internal view returns (uint256 total) {
        for (uint256 i; i < 4; ++i) {
            total += hook.accrued(i);
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_hookEthEqualsWhatItOwes() public view {
        assertEq(address(hook).balance, _sumAccrued() + hook.openingTaxAccrued());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_hookNeverKeepsInfera() public view {
        assertEq(InferaToken(hook.infera()).balanceOf(address(hook)), 0);
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_everyWeiIsAccountedFor() public view {
        for (uint256 i; i < 4; ++i) {
            uint256 inflow = hook.collected(i) + (i == 1 ? hook.withheldEth() : 0);
            assertEq(inflow, hook.accrued(i) + hook.released(i));
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_programmableAlwaysGetsAtLeastItsShare() public view {
        // Programmable's share of all fees is at least 30 of every 230 bps charged. It rounds up per
        // trade; Infera's side of an exact-output quote can round up by 1 wei, which allows at most
        // 30 wei of slack per swap in this ratio.
        uint256 fees = hook.collected(0) + hook.collected(1) + hook.collected(2) + hook.collected(3);
        assertGe(hook.collected(3) * 230 + 30 * handler.swaps(), fees * 30);
    }
}

/// Random actions during and around launch protection: buyers buying through the router (exact
/// input and output), selling, time moving across the 30-second and 300-second marks, payouts.
contract ProtectionHandler is Test {
    IPoolManager internal immutable manager;
    PoolSwapTest internal immutable swapRouter;
    ProtectedRouterMock internal immutable router;
    InferaToken internal immutable token;
    InferaEthHook internal immutable hook;
    PoolKey internal key;
    address[4] public buyers;

    uint256 public taxAfterOpening;
    bool public openingOver;

    constructor(
        IPoolManager manager_,
        PoolSwapTest swapRouter_,
        ProtectedRouterMock router_,
        InferaToken token_,
        InferaEthHook hook_,
        address[4] memory buyers_
    ) {
        manager = manager_;
        swapRouter = swapRouter_;
        router = router_;
        token = token_;
        hook = hook_;
        key = hook_.poolKey();
        buyers = buyers_;
        for (uint256 i; i < 4; ++i) {
            vm.deal(buyers_[i], 1_000 ether);
            vm.startPrank(buyers_[i]);
            token_.approve(address(swapRouter_), type(uint256).max);
            vm.stopPrank();
        }
    }

    /// Records the opening tax collected once 30 seconds have passed: it must never grow after.
    modifier observeOpening() {
        if (!openingOver && block.timestamp >= token.startedAt() + 30) {
            openingOver = true;
            taxAfterOpening = hook.openingTaxCollected();
        }
        _;
    }

    function buy(uint256 who, uint256 amount, bool exactOut) external observeOpening {
        address buyer = buyers[who % 4];
        router.setMsgSender(buyer);
        int256 specified =
            exactOut ? int256(bound(amount, 1e15, 25_000_000 ether)) : -int256(bound(amount, 1e9, 0.5 ether));
        vm.prank(buyer);
        try router.swap{value: 1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: specified, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {}
            catch {}
    }

    function sell(uint256 who, uint256 fraction) external observeOpening {
        address seller = buyers[who % 4];
        uint256 amount = token.balanceOf(seller) * bound(fraction, 1, 100) / 100;
        if (amount == 0) return;
        vm.prank(seller);
        try swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {}
            catch {}
    }

    function wait(uint256 secondsToWait) external observeOpening {
        vm.warp(block.timestamp + bound(secondsToWait, 1, 40));
        vm.roll(block.number + 1);
    }

    function releaseAll() external observeOpening {
        hook.releaseAll();
    }
}

contract InferaLaunchProtectionInvariantTest is Test, Deployers {
    address constant PROGRAMMABLE = 0xD88539d3c4C460136a733A3Fd60cf6BF269079da;
    InferaEthHook hook;
    InferaToken token;
    ProtectionHandler handler;
    address[4] buyers;

    function setUp() public {
        vm.warp(1_794_400_000);
        deployFreshManagerAndRouters();
        vm.deal(address(manager), 55_000 ether); // Mainnet-like native ETH in the PoolManager
        MockEthUsdFeed feed = new MockEthUsdFeed(205_776_678_409);
        ProtectedRouterMock router = new ProtectedRouterMock(manager);
        address launcher = makeAddr("graphFactory");
        address developer = makeAddr("launchWallet");
        InferaLaunchInitializer initializer =
            new InferaLaunchInitializer(manager, launcher, IEthUsdFeed(address(feed)), address(feed).codehash);
        token = new InferaToken("Infera", "INFERA", 1_000_000_000 ether, address(initializer), address(manager));
        address at = address(uint160(InferaEthConfig.HOOK_FLAGS) | (uint160(0x4444) << 144));
        deployCodeTo(
            "InferaEthHook.sol:InferaEthHook",
            HookArgs.encode(
                manager,
                address(token),
                3000,
                60,
                developer,
                [makeAddr("team"), makeAddr("buybacks"), makeAddr("compute")],
                address(initializer),
                developer,
                address(router)
            ),
            at
        );
        hook = InferaEthHook(payable(at));
        vm.deal(launcher, 1 ether);
        vm.prank(launcher);
        initializer.initialize{value: 4_859_637_193_736_836}(hook, address(token), 187_320, developer, 1);

        buyers = [makeAddr("buyer0"), makeAddr("buyer1"), makeAddr("buyer2"), developer];
        handler = new ProtectionHandler(manager, swapRouter, router, token, hook, buyers);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 48
    function invariant_feesAndOpeningTaxAreBacked() public view {
        uint256 owed = hook.openingTaxAccrued();
        for (uint256 i; i < 4; ++i) {
            owed += hook.accrued(i);
        }
        assertEq(address(hook).balance, owed);
        assertEq(hook.openingTaxCollected(), hook.openingTaxAccrued() + hook.openingTaxReleased());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 48
    function invariant_noBuyerBuysAndNoAddressReceivesMoreThan2Percent() public view {
        uint256 limit = token.walletTokenLimit();
        for (uint256 i; i < 4; ++i) {
            assertLe(hook.boughtDuringProtection(buyers[i]), limit);
            assertLe(token.receivedDuringProtection(buyers[i]), limit);
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 48
    function invariant_theOpeningTaxStopsAfter30SecondsAndOnlyReachesProgrammable() public view {
        if (handler.openingOver()) assertEq(hook.openingTaxCollected(), handler.taxAfterOpening());
        // Programmable's treasury receives exactly its 0.3% bucket and the opening tax, nothing else.
        assertEq(PROGRAMMABLE.balance, hook.released(3) + hook.openingTaxReleased());
    }
}
