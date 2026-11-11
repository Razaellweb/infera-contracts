// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {InferaEthHook} from "../src/InferaEthHook.sol";
import {InferaEthConfig} from "../src/InferaEthConfig.sol";
import {DeployInferaEthHook} from "../script/DeployInferaEthHook.s.sol";
import {InferaToken} from "../src/InferaToken.sol";
import {InferaLaunchInitializer} from "../src/InferaLaunchInitializer.sol";

/// Runs only on an Ethereum Mainnet fork (`forge test --fork-url <mainnet RPC>`); skipped otherwise.
/// Deploys through the real deploy script against the live canonical PoolManager.
contract InferaEthHookForkTest is Test {
    function test_fork_deployScriptAndSwapsOnTheCanonicalPoolManager() public {
        if (block.chainid != InferaEthConfig.CHAIN_ID) {
            vm.skip(true);
            return;
        }
        IPoolManager manager = IPoolManager(InferaEthConfig.POOL_MANAGER);
        MockERC20 token = new MockERC20("Infera", "INFERA", 18);
        address owner = makeAddr("owner");

        InferaEthHook hook = new DeployInferaEthHook().run(address(token), owner);
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.owner(), owner);

        PoolSwapTest swapRouter = new PoolSwapTest(manager);
        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(manager);
        token.mint(address(this), 1_000_000 ether);
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(lpRouter), type(uint256).max);
        vm.deal(address(this), 2_000 ether);

        PoolKey memory key = hook.poolKey();
        manager.initialize(key, 79228162514264337593543950336); // 1:1
        lpRouter.modifyLiquidity{value: 1_000 ether}(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 500 ether,
                salt: 0
            }),
            ""
        );

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            settings,
            ""
        );
        assertEq(hook.accrued(3), 0.003 ether, "Programmable 0.3% of a 1 ETH buy");
        assertEq(hook.accrued(0) + hook.accrued(1) + hook.accrued(2), 0.02 ether, "Infera 2% of a 1 ETH buy");

        uint256 ethBefore = address(this).balance;
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: -0.5 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            settings,
            ""
        );
        assertGt(address(this).balance, ethBefore, "sell paid out ETH");
        assertGt(hook.accrued(3), 0.003 ether, "the sell also paid Programmable");
        assertEq(address(hook).balance, hook.accrued(0) + hook.accrued(1) + hook.accrued(2) + hook.accrued(3));

        hook.releaseAll();
        assertEq(address(hook).balance, 0);
        assertGt(InferaEthConfig.TEAM_RECIPIENT.balance, 0);
    }

    receive() external payable {}

    /// The whole launch against the live PoolManager: token minted to the initializer, the hook
    /// bound to it, then the initializer opening the pool with the USD 10 first buy.
    function test_fork_fullLaunchThenTradingAndFeeCollection() public {
        if (block.chainid != InferaEthConfig.CHAIN_ID) {
            vm.skip(true);
            return;
        }
        IPoolManager manager = IPoolManager(InferaEthConfig.POOL_MANAGER);
        address launcher = makeAddr("graphFactory");
        address launchWallet = makeAddr("launchWallet");
        InferaLaunchInitializer initializer = new InferaLaunchInitializer(manager, launcher);
        InferaToken token = new InferaToken("Infera", "INFERA", 1_000_000_000 ether, address(initializer));
        address at = address(uint160(InferaEthConfig.HOOK_FLAGS) | (uint160(0x4444) << 144));
        deployCodeTo(
            "InferaEthHook.sol:InferaEthHook",
            abi.encode(
                manager,
                address(token),
                InferaEthConfig.LP_FEE,
                InferaEthConfig.TICK_SPACING,
                launchWallet,
                InferaEthConfig.TEAM_RECIPIENT,
                InferaEthConfig.BUYBACKS_RECIPIENT,
                InferaEthConfig.COMPUTE_RECIPIENT
            ),
            at
        );
        InferaEthHook hook = InferaEthHook(payable(at));

        vm.deal(launcher, 1 ether);
        vm.prank(launcher);
        initializer.initialize{value: 4_859_637_193_736_836}(hook, address(token), 187_320, launchWallet, 600_000 ether);
        assertGt(token.balanceOf(launchWallet), 600_000 ether, "the USD 10 first buy");

        PoolKey memory key = hook.poolKey();
        PoolSwapTest swapRouter = new PoolSwapTest(manager);
        address trader = makeAddr("trader");
        vm.deal(trader, 10 ether);
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        vm.roll(block.number + 1);
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

        uint256 owed = hook.accrued(0) + hook.accrued(1) + hook.accrued(2) + hook.accrued(3);
        assertEq(address(hook).balance, owed, "hook fees fully backed");
        hook.releaseAll();
        assertGt(InferaEthConfig.BUYBACKS_RECIPIENT.balance, 0, "buybacks wallet paid");
        (uint256 eth, uint256 infera) = initializer.collectPoolFees();
        assertGt(eth + infera, 0, "the locked position's LP fees reach buybacks");
    }
}
