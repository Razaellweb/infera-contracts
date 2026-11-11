// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {InferaEthHook} from "../src/InferaEthHook.sol";
import {InferaEthConfig} from "../src/InferaEthConfig.sol";
import {InferaToken} from "../src/InferaToken.sol";
import {InferaLaunchInitializer, IEthUsdFeed} from "../src/InferaLaunchInitializer.sol";
import {MockEthUsdFeed, ProtectedRouterMock} from "./utils/LaunchFixtures.sol";

/// The full launch on a real v4 PoolManager, the way Programmable's graph factory runs it, and
/// Programmable's launch-protection rules: the opening valuation check against the ETH/USD feed,
/// the 2% receiving and buying limits for 300 seconds, router-only buys while they last, and the
/// 30-second opening tax.
contract InferaLaunchTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant LIMIT = 20_000_000 ether; // 2% of supply
    int24 constant START_TICK = 187_320; // ~136.4M INFERA per ETH: about USD 15,087 FDV at USD 2,057.77/ETH
    uint256 constant FIRST_BUY = 4_859_637_193_736_836; // USD 10 at USD 2,057.77/ETH
    int256 constant ETH_USD_8DP = 205_776_678_409; // Chainlink ETH/USD on 2026-11-11
    uint256 constant LAUNCH_TIME = 1_794_400_000;
    address constant PROGRAMMABLE = 0xD88539d3c4C460136a733A3Fd60cf6BF269079da;

    address launcher = makeAddr("graphFactory");
    address launchWallet = makeAddr("launchWallet"); // developer, owner and first buyer
    address vip = makeAddr("vip"); // one extra opening-tax-exempt wallet
    address team = makeAddr("team");
    address buybacks = makeAddr("buybacks");
    address compute = makeAddr("compute");

    MockEthUsdFeed feed;
    ProtectedRouterMock router;
    InferaLaunchInitializer initializer;
    InferaToken token;
    InferaEthHook hook;

    function setUp() public {
        vm.warp(LAUNCH_TIME);
        deployFreshManagerAndRouters();
        feed = new MockEthUsdFeed(ETH_USD_8DP);
        router = new ProtectedRouterMock(manager);
        initializer = new InferaLaunchInitializer(manager, launcher, IEthUsdFeed(address(feed)), address(feed).codehash);
        token = new InferaToken("Infera", "INFERA", SUPPLY, address(initializer), address(manager));
        address at = address(uint160(InferaEthConfig.HOOK_FLAGS) | (uint160(0x4444) << 144));
        address[6] memory exempt;
        exempt[0] = vip;
        deployCodeTo(
            "InferaEthHook.sol:InferaEthHook",
            abi.encode(
                manager,
                address(token),
                uint24(3000),
                int24(60),
                InferaEthHook.Recipients({owner: launchWallet, team: team, buybacks: buybacks, compute: compute}),
                InferaEthHook.Protection({
                    initializer: address(initializer),
                    developer: launchWallet,
                    router: address(router),
                    routerCodeHash: address(router).codehash,
                    exemptWallets: exempt
                })
            ),
            at
        );
        hook = InferaEthHook(payable(at));
        key = hook.poolKey();
        vm.deal(launcher, 1 ether);
        // Exact-input buy fees are taken from the PoolManager's ETH before the buyer settles. The
        // Mainnet PoolManager holds about 55,000 ETH; a fresh local one holds none.
        vm.deal(address(manager), 55_000 ether);
    }

    // ------------------------------------------------------------ helpers

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
        vm.deal(t, 1_000 ether);
        vm.startPrank(t);
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    /// A buy through the protected router, which reports `buyer` as the buyer.
    function _routerBuy(address buyer, int256 amountSpecified, uint256 maxEth) internal {
        router.setMsgSender(buyer);
        _routerSwap(buyer, amountSpecified, maxEth);
    }

    /// The swap half of {_routerBuy}: call it right after `vm.expectRevert`.
    function _routerSwap(address buyer, int256 amountSpecified, uint256 maxEth) internal {
        vm.prank(buyer);
        router.swap{value: maxEth}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: amountSpecified, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    /// A swap through a plain router, as any router is allowed once protection ends (sells always).
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
        uint256 owed = hook.openingTaxAccrued();
        for (uint256 i; i < 4; ++i) {
            owed += hook.accrued(i);
        }
        assertEq(address(hook).balance, owed, "fees and opening tax are exactly backed");
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(hook.openingTaxCollected(), hook.openingTaxAccrued() + hook.openingTaxReleased());
    }

    // ------------------------------------------------------------ the launch

    function test_launchSeedsAndLocksTheWholeSupplyAndMakesTheFirstBuy() public {
        _launch(600_000 ether);

        assertTrue(initializer.initialized());
        assertEq(token.startedAt(), block.timestamp, "trading and protection start at the launch");
        uint128 locked = initializer.lockedLiquidity();
        assertGt(locked, 0);
        assertEq(_positionLiquidity(), locked, "the initializer owns the whole position");
        assertEq(initializer.tickUpper(), START_TICK);
        assertEq(initializer.tickLower(), TickMath.minUsableTick(60));

        uint256 bought = token.balanceOf(launchWallet);
        assertGt(bought, 600_000 ether, "the USD 10 buy returns about 0.065% of supply");
        assertLt(bought, 650_000 ether);
        uint256 dust = token.balanceOf(address(initializer));
        assertLt(dust, 1e9, "only rounding dust stays in the initializer");
        assertEq(token.balanceOf(address(manager)) + bought + dust, SUPPLY, "every token is accounted for");

        // The developer's first buy pays the normal fees, no opening tax, and counts toward its 2%.
        assertEq(hook.accrued(3), (FIRST_BUY * 30 + 9_999) / 10_000, "Programmable's 0.3%, rounded up");
        assertApproxEqAbs(hook.accrued(0) + hook.accrued(1) + hook.accrued(2), FIRST_BUY * 200 / 10_000, 1);
        assertEq(hook.openingTaxAccrued(), 0, "the developer is exempt from the opening tax");
        assertEq(hook.boughtDuringProtection(launchWallet), bought, "and counted toward its 2%");
        _assertHookBacked();
    }

    function test_theOpeningValuationIsCheckedAgainstTheEthUsdFeed() public {
        _launch(1);
        assertEq(initializer.openingFdvUsd(), 15_086, "USD 15,086.85, rounded down");
        // The same figure, computed independently: supply * 2^192 / sqrtPrice^2 ETH at the feed price.
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(START_TICK);
        uint256 fdvEth = FullMath.mulDiv(FullMath.mulDiv(SUPPLY, 1 << 96, sqrtPrice), 1 << 96, sqrtPrice);
        assertEq(fdvEth * uint256(ETH_USD_8DP) / 1e8 / 1 ether, 15_086);
    }

    function test_aValuationBelowUsd15kRevertsTheLaunch() public {
        feed.set(1_000e8, block.timestamp); // at USD 1,000/ETH the same price is about USD 7,332
        vm.prank(launcher);
        vm.expectRevert(abi.encodeWithSelector(InferaLaunchInitializer.OpeningValuationTooLow.selector, 7_331));
        initializer.initialize{value: FIRST_BUY}(hook, address(token), START_TICK, launchWallet, 1);
    }

    function test_aStaleFutureOrNonPositivePriceRevertsTheLaunch() public {
        vm.startPrank(launcher);
        feed.set(ETH_USD_8DP, block.timestamp - 24 hours - 1); // older than the allowed age
        vm.expectRevert(InferaLaunchInitializer.InvalidOraclePrice.selector);
        initializer.initialize{value: FIRST_BUY}(hook, address(token), START_TICK, launchWallet, 1);
        feed.set(ETH_USD_8DP, block.timestamp + 1); // from the future
        vm.expectRevert(InferaLaunchInitializer.InvalidOraclePrice.selector);
        initializer.initialize{value: FIRST_BUY}(hook, address(token), START_TICK, launchWallet, 1);
        feed.set(0, block.timestamp);
        vm.expectRevert(InferaLaunchInitializer.InvalidOraclePrice.selector);
        initializer.initialize{value: FIRST_BUY}(hook, address(token), START_TICK, launchWallet, 1);
        feed.set(-1, block.timestamp);
        vm.expectRevert(InferaLaunchInitializer.InvalidOraclePrice.selector);
        initializer.initialize{value: FIRST_BUY}(hook, address(token), START_TICK, launchWallet, 1);
        vm.stopPrank();
    }

    function test_theFeedMustMatchItsExpectedCode() public {
        vm.expectRevert(InferaLaunchInitializer.InvalidConfiguration.selector);
        new InferaLaunchInitializer(manager, launcher, IEthUsdFeed(address(feed)), keccak256("other code"));
        vm.expectRevert(InferaLaunchInitializer.InvalidConfiguration.selector);
        new InferaLaunchInitializer(manager, launcher, IEthUsdFeed(makeAddr("noCode")), bytes32(0));
    }

    function test_onlyTheLauncherInitializes_andOnlyOnce() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(InferaLaunchInitializer.NotLauncher.selector);
        initializer.initialize{value: FIRST_BUY}(hook, address(token), START_TICK, launchWallet, 1);

        _launch(1);
        vm.prank(launcher);
        vm.expectRevert(InferaLaunchInitializer.AlreadyInitialized.selector);
        initializer.initialize{value: FIRST_BUY}(hook, address(token), START_TICK, launchWallet, 1);
    }

    function test_rejectsAWrongTokenTickBuyerOrFirstBuy() public {
        vm.startPrank(launcher);
        vm.expectRevert(InferaLaunchInitializer.WrongToken.selector);
        initializer.initialize{value: FIRST_BUY}(hook, makeAddr("other"), START_TICK, launchWallet, 1);
        vm.expectRevert(InferaLaunchInitializer.MisalignedTick.selector);
        initializer.initialize{value: FIRST_BUY}(hook, address(token), START_TICK + 1, launchWallet, 1);
        vm.expectRevert(InferaLaunchInitializer.NoInitialBuy.selector);
        initializer.initialize(hook, address(token), START_TICK, launchWallet, 1);
        vm.expectRevert(InferaLaunchInitializer.NoInitialBuy.selector);
        initializer.initialize{value: FIRST_BUY}(hook, address(token), START_TICK, launchWallet, 0);
        vm.expectRevert(InferaLaunchInitializer.InvalidConfiguration.selector); // not the hook's developer
        initializer.initialize{value: FIRST_BUY}(hook, address(token), START_TICK, makeAddr("someoneElse"), 1);
        vm.stopPrank();
    }

    function test_aFirstBuyBelowItsMinimumRevertsTheWholeLaunch() public {
        vm.prank(launcher);
        vm.expectRevert();
        initializer.initialize{value: FIRST_BUY}(hook, address(token), START_TICK, launchWallet, 10_000_000 ether);
        assertFalse(initializer.initialized(), "nothing happened");
        assertEq(token.startedAt(), 0);
        assertEq(token.balanceOf(address(initializer)), SUPPLY);
    }

    // ------------------------------------------------------------ token: 2% receiving limit

    function test_nothingMovesBeforeTheLaunch() public {
        vm.prank(address(initializer));
        vm.expectRevert(InferaToken.TradingNotStarted.selector);
        token.transfer(makeAddr("anyone"), 1);
        vm.expectRevert(InferaToken.NotInitializer.selector);
        token.start();
    }

    function test_tradingStartsOnce() public {
        _launch(1);
        vm.prank(address(initializer));
        vm.expectRevert(InferaToken.AlreadyStarted.selector);
        token.start();
    }

    function test_eachAddressReceivesAtMost2PercentInTheFirstFiveMinutes() public {
        _launch(1);
        address alice = _trader("alice");
        address bob = _trader("bob");
        vm.warp(LAUNCH_TIME + 60); // after the opening tax, inside the protection window
        _routerBuy(alice, 15_000_000 ether, 10 ether); // exact-output: 1.5% of supply
        _routerBuy(bob, 15_000_000 ether, 10 ether);

        // Bob forwarding 1% would take Alice to 2.5%.
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(InferaToken.WalletLimitExceeded.selector, alice, 25_000_000 ether, LIMIT)
        );
        token.transfer(alice, 10_000_000 ether);

        // Selling does not restore Alice's budget: she has received 1.5% either way.
        vm.roll(block.number + 1);
        _swap(alice, false, -int256(token.balanceOf(alice)));
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(InferaToken.WalletLimitExceeded.selector, alice, 25_000_000 ether, LIMIT)
        );
        token.transfer(alice, 10_000_000 ether);

        // A self-transfer neither gains nor uses budget.
        vm.prank(bob);
        token.transfer(bob, 1_000 ether);
        assertEq(token.receivedDuringProtection(bob), 15_000_000 ether);

        // After five minutes there is no limit.
        vm.warp(LAUNCH_TIME + 300);
        vm.prank(bob);
        token.transfer(alice, 10_000_000 ether);
        assertEq(token.balanceOf(alice), 10_000_000 ether);
    }

    // ------------------------------------------------------------ hook: authenticated buyers, 2% buying limit

    function test_duringProtectionBuysMustComeThroughTheRouter() public {
        _launch(1);
        address alice = _trader("alice");
        vm.warp(LAUNCH_TIME + 60);
        vm.expectRevert(); // InferaEthHook.UnsupportedRouter, wrapped by the PoolManager
        _swap(alice, true, -0.01 ether);

        router.setMsgSender(address(0));
        vm.expectRevert(); // the router must name a buyer: InferaEthHook.InvalidBuyer
        _routerSwap(alice, -0.01 ether, 0.01 ether);

        _routerBuy(alice, -0.01 ether, 0.01 ether);
        assertEq(hook.boughtDuringProtection(alice), token.balanceOf(alice));

        // An impostor with the same code at another address, reporting any buyer it likes, is refused:
        // otherwise a bot could name a fresh "buyer" on every buy and dodge the 2% limit.
        ProtectedRouterMock impostor = new ProtectedRouterMock(manager);
        impostor.setMsgSender(makeAddr("freshWallet"));
        vm.prank(alice);
        vm.expectRevert(); // InferaEthHook.UnsupportedRouter
        impostor.swap{value: 0.01 ether}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -0.01 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    function test_eachBuyerBuysAtMost2PercentInTheFirstFiveMinutes_soldOrNot() public {
        _launch(1);
        address alice = _trader("alice");
        vm.warp(LAUNCH_TIME + 60);
        _routerBuy(alice, 19_000_000 ether, 10 ether);
        vm.roll(block.number + 1);
        _swap(alice, false, -int256(token.balanceOf(alice))); // sells are never restricted
        assertEq(token.balanceOf(alice), 0);
        vm.roll(block.number + 1);
        router.setMsgSender(alice);
        vm.expectRevert(); // 1.9% + 0.2% > 2%: InferaEthHook.BuyerLimitExceeded
        _routerSwap(alice, 2_000_000 ether, 10 ether);
        _routerBuy(alice, 1_000_000 ether, 10 ether); // exactly 2% in total is fine
        assertEq(hook.boughtDuringProtection(alice), LIMIT);
    }

    /// The router identifies the buyer, while the tokens can go to any recipient. The token's limit
    /// counts each recipient; this limit counts the buyer, so spreading buys over fresh recipient
    /// wallets does not get a sniper past 2%.
    function test_theBuyLimitFollowsTheBuyerNotWhereTheTokensGo() public {
        _launch(1);
        address alice = makeAddr("alice"); // the buyer the router reports
        address freshOne = _trader("freshOne"); // pays and receives
        address freshTwo = _trader("freshTwo");
        vm.warp(LAUNCH_TIME + 60);
        router.setMsgSender(alice);
        _routerSwap(freshOne, 15_000_000 ether, 10 ether); // 1.5% to freshOne
        assertEq(hook.boughtDuringProtection(alice), 15_000_000 ether);
        vm.expectRevert(); // another 1% to freshTwo is within its own 2%, but Alice would be at 2.5%
        _routerSwap(freshTwo, 10_000_000 ether, 10 ether);
        _routerSwap(freshTwo, 5_000_000 ether, 10 ether); // up to exactly 2% for Alice is fine
        assertEq(hook.boughtDuringProtection(alice), LIMIT);
    }

    function test_theDeveloperAndExemptWalletsAreLimitedToo() public {
        _launch(1);
        _trader("launchWallet");
        address vipTrader = _trader("vip");
        assertEq(vipTrader, vip);
        vm.warp(LAUNCH_TIME + 60);
        uint256 developerBought = hook.boughtDuringProtection(launchWallet);
        router.setMsgSender(launchWallet);
        vm.expectRevert();
        _routerSwap(launchWallet, int256(LIMIT - developerBought + 1), 10 ether);
        _routerBuy(launchWallet, int256(LIMIT - developerBought), 10 ether);
        router.setMsgSender(vip);
        vm.expectRevert();
        _routerSwap(vip, int256(LIMIT + 1), 10 ether);
    }

    function test_afterFiveMinutesAnyRouterBuysWithoutALimit() public {
        _launch(1);
        address alice = _trader("alice");
        vm.warp(LAUNCH_TIME + 300);
        assertFalse(hook.protectionActive());
        _swap(alice, true, -5 ether);
        assertGt(token.balanceOf(alice), LIMIT, "more than 2%, through a plain router");
        assertEq(hook.boughtDuringProtection(alice), 0, "nothing is counted any more");
    }

    // ------------------------------------------------------------ hook: opening tax

    function test_theOpeningBuyFeeStartsAt99PercentAndFallsToNormalOver30Seconds() public {
        _launch(1);
        address alice = _trader("alice");
        assertEq(hook.openingTaxPpm(alice), 967_000, "99% total less the normal 2.3%");
        vm.warp(LAUNCH_TIME + 15);
        assertEq(hook.openingTaxPpm(alice), 483_500, "half way");
        vm.warp(LAUNCH_TIME + 29);
        assertEq(hook.openingTaxPpm(alice), 32_233);
        vm.warp(LAUNCH_TIME + 30);
        assertEq(hook.openingTaxPpm(alice), 0, "normal fees from 30 seconds");
        assertEq(hook.openingTaxPpm(launchWallet), 0);
    }

    function test_anOpeningBuyPaysTheTaxToProgrammableOnly() public {
        _launch(1);
        address alice = _trader("alice");
        vm.roll(block.number + 1); // same second as the launch, next block
        uint256 ethBefore = alice.balance;
        uint256[4] memory feesBefore;
        for (uint256 i; i < 4; ++i) {
            feesBefore[i] = hook.accrued(i);
        }
        _routerBuy(alice, -1 ether, 1 ether);

        assertEq(ethBefore - alice.balance, 1 ether);
        (uint256[4] memory fees, uint256 tax,) = hook.quoteBuy(1 ether, false, 967_000);
        assertEq(hook.openingTaxAccrued(), tax);
        assertEq(tax, 0.967 ether, "99% total = 2.3% normal fees + 96.7% opening tax");
        for (uint256 i; i < 4; ++i) {
            assertEq(hook.accrued(i) - feesBefore[i], fees[i], "normal fees are unchanged");
        }
        assertGt(token.balanceOf(alice), 0, "only 1% of the ETH bought INFERA");

        uint256 programmableBefore = PROGRAMMABLE.balance;
        vm.prank(makeAddr("anyone"));
        hook.releaseOpeningTax();
        assertEq(PROGRAMMABLE.balance - programmableBefore, tax, "the tax goes to Programmable's treasury");
        assertEq(hook.openingTaxAccrued(), 0);
        _assertHookBacked();
    }

    function test_exemptWalletsAndTheDeveloperPayNoOpeningTax() public {
        _launch(1);
        _trader("vip");
        _trader("launchWallet");
        vm.roll(block.number + 1);
        _routerBuy(vip, -0.05 ether, 0.05 ether); // about 0.7% of supply, inside the 2% limit
        _routerBuy(launchWallet, -0.05 ether, 0.05 ether);
        assertEq(hook.openingTaxAccrued(), 0);
        assertEq(hook.openingTaxPpm(vip), 0);
    }

    function test_anExactOutputOpeningBuyPaysTheTaxOnTop() public {
        _launch(1);
        address alice = _trader("alice");
        vm.warp(LAUNCH_TIME + 15); // opening tax 48.35%
        uint256 ethBefore = alice.balance;
        _routerBuy(alice, 100_000 ether, 1 ether);
        assertEq(token.balanceOf(alice), 100_000 ether, "exactly the INFERA asked for");
        uint256 paid = ethBefore - alice.balance;
        uint256 fees;
        for (uint256 i; i < 4; ++i) {
            fees += hook.accrued(i);
        }
        fees -= (FIRST_BUY * 30 + 9_999) / 10_000 + FIRST_BUY * 200 / 10_000; // the developer's first buy
        uint256 tax = hook.openingTaxAccrued();
        assertGt(tax, 0);
        // fees + tax are (2.3% + 48.35%) of everything Alice paid.
        assertApproxEqRel(fees + tax, paid * 506_500 / 1_000_000, 1e14);
        _assertHookBacked();
    }

    function test_sellsNeverPayTheOpeningTax() public {
        _launch(1);
        vm.roll(block.number + 1);
        vm.prank(launchWallet);
        token.approve(address(swapRouter), type(uint256).max);
        _swap(launchWallet, false, -int256(token.balanceOf(launchWallet)));
        assertEq(hook.openingTaxAccrued(), 0);
    }

    function test_releaseAllAlsoPaysTheOpeningTax() public {
        _launch(1);
        address alice = _trader("alice");
        vm.roll(block.number + 1);
        _routerBuy(alice, -0.1 ether, 0.1 ether);
        uint256 tax = hook.openingTaxAccrued();
        uint256 programmableBefore = PROGRAMMABLE.balance;
        hook.releaseAll();
        assertEq(PROGRAMMABLE.balance - programmableBefore, tax + (FIRST_BUY * 30 + 9_999) / 10_000 + 0.0003 ether);
        assertEq(address(hook).balance, 0);
        _assertHookBacked();
    }

    // ------------------------------------------------------------ after protection: normal trading

    function test_afterLaunchTradersBuyAndSell() public {
        _launch(1);
        address trader = _trader("trader");
        vm.warp(LAUNCH_TIME + 300);
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
        _launch(1);
        address trader = _trader("trader");
        vm.warp(LAUNCH_TIME + 300);
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
        _launch(1);
        address trader = _trader("trader");
        vm.warp(LAUNCH_TIME + 300);
        _swap(trader, true, -1 ether);
        address newBuybacks = makeAddr("newBuybacks");
        vm.prank(launchWallet); // the hook owner
        hook.setRecipient(InferaEthHook.Bucket.Buybacks, newBuybacks);
        initializer.collectPoolFees();
        assertGt(newBuybacks.balance, 0);
    }

    function test_theLockedPositionCannotBeWithdrawnByAnyoneElse() public {
        _launch(1);
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
