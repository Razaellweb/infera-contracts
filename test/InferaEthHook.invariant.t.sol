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
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {InferaEthHook} from "../src/InferaEthHook.sol";
import {InferaEthConfig} from "../src/InferaEthConfig.sol";

/// Random actions against the real pool: all four swap shapes, new blocks, just-in-time liquidity,
/// payouts and recipient changes. Reverting actions (e.g. an exact-output larger than the pool) are
/// caught, so every sequence keeps going.
contract HookHandler is Test {
    using PoolIdLibrary for PoolKey;

    IPoolManager internal immutable manager;
    PoolSwapTest internal immutable swapRouter;
    PoolModifyLiquidityTest internal immutable lpRouter;
    MockERC20 internal immutable token;
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
        MockERC20 token_,
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
        MockERC20 token = new MockERC20("Infera", "INFERA", 18);
        token.mint(address(this), 1_000_000 ether);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.deal(address(this), 10_000 ether);

        address at = address(uint160(InferaEthConfig.HOOK_FLAGS) | (uint160(0x4444) << 144));
        deployCodeTo(
            "InferaEthHook.sol:InferaEthHook",
            abi.encode(
                manager,
                address(token),
                uint24(3000),
                int24(60),
                makeAddr("owner"),
                makeAddr("team"),
                makeAddr("buybacks"),
                makeAddr("compute")
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

        handler = new HookHandler(manager, swapRouter, modifyLiquidityRouter, token, hook, makeAddr("owner"));
        vm.deal(address(handler), 1_000_000 ether);
        token.mint(address(handler), 1_000_000 ether);
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
        assertEq(address(hook).balance, _sumAccrued());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_hookNeverKeepsInfera() public view {
        assertEq(MockERC20(hook.infera()).balanceOf(address(hook)), 0);
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
