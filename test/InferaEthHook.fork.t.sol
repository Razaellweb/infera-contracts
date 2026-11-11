// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {InferaEthHook} from "../src/InferaEthHook.sol";
import {InferaEthConfig} from "../src/InferaEthConfig.sol";
import {InferaToken} from "../src/InferaToken.sol";
import {InferaLaunchInitializer, IEthUsdFeed} from "../src/InferaLaunchInitializer.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// Runs only on an Ethereum Mainnet fork (`forge test --fork-url <mainnet RPC>`); skipped otherwise.
/// The whole launch against the live PoolManager, the live Chainlink ETH/USD feed and the canonical
/// Universal Router, exactly as the contracts check them on Mainnet.
contract InferaEthHookForkTest is Test {
    address constant FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    bytes32 constant FEED_CODE_HASH = 0x4b79b5c8aee6da0f7b393e8b53e6265ef7320a1d16184c65bd3841b5aa3d700d;
    address constant ROUTER = 0xd92A36B0000531EF3063dEd4De20A0783308446C;

    IPoolManager manager = IPoolManager(InferaEthConfig.POOL_MANAGER);
    address launcher = makeAddr("graphFactory");
    address launchWallet = makeAddr("launchWallet");
    InferaLaunchInitializer initializer;
    InferaToken token;
    InferaEthHook hook;
    PoolKey key;

    function _launch() internal {
        initializer = new InferaLaunchInitializer(manager, launcher, IEthUsdFeed(FEED), FEED_CODE_HASH);
        token = new InferaToken("Infera", "INFERA", 1_000_000_000 ether, address(initializer), address(manager));
        address at = address(uint160(InferaEthConfig.HOOK_FLAGS) | (uint160(0x4444) << 144));
        address[6] memory noExemptions;
        deployCodeTo(
            "InferaEthHook.sol:InferaEthHook",
            abi.encode(
                manager,
                address(token),
                InferaEthConfig.LP_FEE,
                InferaEthConfig.TICK_SPACING,
                InferaEthHook.Recipients({
                    owner: launchWallet,
                    team: InferaEthConfig.TEAM_RECIPIENT,
                    buybacks: InferaEthConfig.BUYBACKS_RECIPIENT,
                    compute: InferaEthConfig.COMPUTE_RECIPIENT
                }),
                InferaEthHook.Protection({
                    initializer: address(initializer),
                    developer: launchWallet,
                    router: ROUTER,
                    routerCodeHash: ROUTER.codehash,
                    exemptWallets: noExemptions
                })
            ),
            at
        );
        hook = InferaEthHook(payable(at));
        key = hook.poolKey();
        vm.deal(launcher, 1 ether);
        int24 startTick = _startTickFor(20_000);
        vm.prank(launcher);
        initializer.initialize{value: 4_859_637_193_736_836}(hook, address(token), startTick, launchWallet, 1);
    }

    /// The opening tick (a multiple of 60) for a USD `fdvUsd` valuation at the live ETH/USD price,
    /// rounded toward a higher valuation, so the test runs whatever ETH trades at today.
    function _startTickFor(uint256 fdvUsd) internal view returns (int24 tick) {
        (, int256 answer,,,) = IEthUsdFeed(FEED).latestRoundData();
        // INFERA per ETH = supply * (USD per ETH) / FDV, as a Q192 price, then its square root.
        uint256 priceX192 = FullMath.mulDiv(uint256(1_000_000_000) * uint256(answer), 1 << 192, fdvUsd * 1e8);
        tick = TickMath.getTickAtSqrtPrice(uint160(FixedPointMathLib.sqrt(priceX192)));
        tick -= tick % 60;
    }

    /// An exact-input ETH -> INFERA buy through the Universal Router's V4_SWAP command:
    /// SWAP_EXACT_IN_SINGLE, SETTLE_ALL (native ETH), TAKE_ALL (INFERA).
    function _universalRouterBuy(address buyer, uint128 amountIn) internal {
        bytes memory actions = abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(key, true, amountIn, uint128(1), bytes(""));
        params[1] = abi.encode(key.currency0, uint256(amountIn));
        params[2] = abi.encode(key.currency1, uint256(1));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        vm.prank(buyer);
        IUniversalRouter(ROUTER).execute{value: amountIn}(abi.encodePacked(uint8(0x10)), inputs, block.timestamp);
    }

    function test_fork_launchChecksTheLiveEthUsdPrice() public {
        if (block.chainid != InferaEthConfig.CHAIN_ID) {
            vm.skip(true);
            return;
        }
        (, int256 answer,, uint256 updatedAt,) = IEthUsdFeed(FEED).latestRoundData();
        if (block.timestamp - updatedAt > 1 hours) vm.warp(updatedAt + 1); // keep the live price fresh
        _launch();
        uint256 fdv = initializer.openingFdvUsd();
        assertGe(fdv, 20_000, "the opening valuation was checked against the live price");
        assertLt(fdv, 20_200);
        emit log_named_uint("live ETH/USD (8 decimals)", uint256(answer));
        emit log_named_uint("opening FDV (USD)", fdv);
        assertEq(token.startedAt(), block.timestamp);
        assertGt(token.balanceOf(launchWallet), 0, "the developer's first buy");
    }

    function test_fork_duringProtectionBuyersAreIdentifiedByTheUniversalRouter() public {
        if (block.chainid != InferaEthConfig.CHAIN_ID) {
            vm.skip(true);
            return;
        }
        (,,, uint256 updatedAt,) = IEthUsdFeed(FEED).latestRoundData();
        if (block.timestamp - updatedAt > 1 hours) vm.warp(updatedAt + 1);
        _launch();
        address alice = makeAddr("alice");
        vm.deal(alice, 1 ether);
        vm.warp(block.timestamp + 60); // after the opening tax, inside the protection window

        _universalRouterBuy(alice, 0.05 ether);
        assertGt(token.balanceOf(alice), 0);
        assertEq(hook.boughtDuringProtection(alice), token.balanceOf(alice), "the router reported alice as the buyer");

        // A plain router is refused while protection lasts.
        PoolSwapTest plain = new PoolSwapTest(manager);
        vm.prank(alice);
        vm.expectRevert();
        plain.swap{value: 0.01 ether}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -0.01 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_fork_afterProtectionTradingPayoutsAndFeeCollection() public {
        if (block.chainid != InferaEthConfig.CHAIN_ID) {
            vm.skip(true);
            return;
        }
        (,,, uint256 updatedAt,) = IEthUsdFeed(FEED).latestRoundData();
        if (block.timestamp - updatedAt > 1 hours) vm.warp(updatedAt + 1);
        _launch();
        vm.warp(block.timestamp + 300);

        PoolSwapTest swapRouter = new PoolSwapTest(manager);
        address trader = makeAddr("trader");
        vm.deal(trader, 10 ether);
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        vm.prank(trader);
        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            settings,
            ""
        );
        uint256 bought = token.balanceOf(trader);
        vm.roll(block.number + 1);
        vm.startPrank(trader);
        token.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(bought / 2), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            settings,
            ""
        );
        vm.stopPrank();

        uint256 owed = hook.openingTaxAccrued();
        for (uint256 i; i < 4; ++i) {
            owed += hook.accrued(i);
        }
        assertEq(address(hook).balance, owed, "hook fees fully backed");
        hook.releaseAll();
        assertGt(InferaEthConfig.BUYBACKS_RECIPIENT.balance, 0, "buybacks wallet paid");
        (uint256 eth, uint256 infera) = initializer.collectPoolFees();
        assertGt(eth + infera, 0, "the locked position's LP fees reach buybacks");
    }

    function test_fork_aValuationBelowUsd15kAtTheLivePriceRevertsTheLaunch() public {
        if (block.chainid != InferaEthConfig.CHAIN_ID) {
            vm.skip(true);
            return;
        }
        (,,, uint256 updatedAt,) = IEthUsdFeed(FEED).latestRoundData();
        if (block.timestamp - updatedAt > 1 hours) vm.warp(updatedAt + 1);
        initializer = new InferaLaunchInitializer(manager, launcher, IEthUsdFeed(FEED), FEED_CODE_HASH);
        token = new InferaToken("Infera", "INFERA", 1_000_000_000 ether, address(initializer), address(manager));
        address at = address(uint160(InferaEthConfig.HOOK_FLAGS) | (uint160(0x4444) << 144));
        address[6] memory noExemptions;
        deployCodeTo(
            "InferaEthHook.sol:InferaEthHook",
            abi.encode(
                manager,
                address(token),
                InferaEthConfig.LP_FEE,
                InferaEthConfig.TICK_SPACING,
                InferaEthHook.Recipients({
                    owner: launchWallet,
                    team: InferaEthConfig.TEAM_RECIPIENT,
                    buybacks: InferaEthConfig.BUYBACKS_RECIPIENT,
                    compute: InferaEthConfig.COMPUTE_RECIPIENT
                }),
                InferaEthHook.Protection({
                    initializer: address(initializer),
                    developer: launchWallet,
                    router: ROUTER,
                    routerCodeHash: ROUTER.codehash,
                    exemptWallets: noExemptions
                })
            ),
            at
        );
        hook = InferaEthHook(payable(at));
        vm.deal(launcher, 1 ether);
        int24 tooCheap = _startTickFor(14_000) + 60; // a little under USD 14,000
        vm.prank(launcher);
        vm.expectRevert(); // InferaLaunchInitializer.OpeningValuationTooLow
        initializer.initialize{value: 0.001 ether}(hook, address(token), tooCheap, launchWallet, 1);
    }
}
