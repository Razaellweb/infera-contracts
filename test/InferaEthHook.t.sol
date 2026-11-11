// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {InferaEthHook} from "../src/InferaEthHook.sol";
import {InferaEthConfig} from "../src/InferaEthConfig.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";

/// Deploys InferaEthHook through CREATE2 from a contract, the way a deployer proxy or
/// Programmable's router would, to prove ownership does not go to the deploying contract.
contract HookFactory {
    function deploy(bytes32 salt, bytes memory args) external returns (address hook) {
        bytes memory code = abi.encodePacked(type(InferaEthHook).creationCode, args);
        assembly {
            hook := create2(0, add(code, 0x20), mload(code), salt)
        }
        require(hook != address(0), "create2 failed");
    }
}

contract RejectsEther {}

/// A recipient that calls back into the hook when paid. With `swallow`, it catches the failed
/// re-entry and accepts the ETH; without, its receive reverts.
contract ReentrantRecipient {
    InferaEthHook public hook;
    bool public immutable swallow;
    uint256 public calls;

    constructor(bool swallow_) {
        swallow = swallow_;
    }

    function setHook(InferaEthHook hook_) external {
        hook = hook_;
    }

    receive() external payable {
        ++calls;
        if (swallow) {
            try hook.releaseAll() {} catch {}
        } else {
            hook.release(InferaEthHook.Bucket.Team);
        }
    }
}

/// A token that can switch on a 1% transfer tax, standing in for a non-standard INFERA.
contract TaxableToken is MockERC20 {
    bool public taxOn;

    constructor() MockERC20("Taxed", "TAX", 18) {}

    function setTax(bool on) external {
        taxOn = on;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (!taxOn) return super.transfer(to, amount);
        balanceOf[msg.sender] -= amount;
        _credit(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (!taxOn) return super.transferFrom(from, to, amount);
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        _credit(from, to, amount);
        return true;
    }

    function _credit(address from, address to, uint256 amount) private {
        uint256 tax = amount / 100;
        unchecked {
            balanceOf[to] += amount - tax;
            totalSupply -= tax;
        }
        emit Transfer(from, to, amount - tax);
    }
}

/// Every swap below runs through a real Uniswap v4 PoolManager (v4-core), not a mock.
contract InferaEthHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    InferaEthHook hook;
    MockERC20 token;
    PoolKey poolKeyEthInfera;

    address owner = makeAddr("owner");
    address team = makeAddr("team");
    address buybacks = makeAddr("buybacks");
    address compute = makeAddr("compute");
    address constant PROGRAMMABLE = 0xD88539d3c4C460136a733A3Fd60cf6BF269079da;

    uint256 constant TEAM = 0;
    uint256 constant BUYBACKS = 1;
    uint256 constant COMPUTE = 2;
    uint256 constant PROG = 3;

    function setUp() public {
        deployFreshManagerAndRouters();
        token = new MockERC20("Infera", "INFERA", 18);
        token.mint(address(this), 1_000_000 ether);
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.deal(address(this), 10_000 ether);

        address hookAddress = address(uint160(InferaEthConfig.HOOK_FLAGS) | (uint160(0x4444) << 144));
        deployCodeTo(
            "InferaEthHook.sol:InferaEthHook",
            abi.encode(manager, address(token), uint24(3000), int24(60), owner, team, buybacks, compute),
            hookAddress
        );
        hook = InferaEthHook(payable(hookAddress));
        poolKeyEthInfera = hook.poolKey();

        manager.initialize(poolKeyEthInfera, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity{value: 1_000 ether}(
            poolKeyEthInfera,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 500 ether,
                salt: 0
            }),
            ZERO_BYTES
        );
    }

    // ------------------------------------------------------------ helpers

    function _swap(bool buy, int256 amountSpecified, uint256 value) internal {
        swapRouter.swap{value: value}(
            poolKeyEthInfera,
            SwapParams({
                zeroForOne: buy,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    bytes32 constant CAP_EVENT = keccak256("BlockStartPriceEnforced(bool,bool,uint256,address)");

    /// Swaps on `key` from `trader`, stopping at `limit` (0 = no limit). Returns the trader's deltas.
    function _swapAs(address trader, PoolKey memory key, bool buy, int256 amountSpecified, uint160 limit)
        internal
        returns (uint256 ethDelta, uint256 inferaDelta)
    {
        uint256 ethBefore = trader.balance;
        uint256 inferaBefore = token.balanceOf(trader);
        if (limit == 0) limit = buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        vm.prank(trader);
        swapRouter.swap{value: buy ? 1_000 ether : 0}(
            key,
            SwapParams({zeroForOne: buy, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        // Buys: ETH paid and INFERA received. Sells: ETH received and INFERA paid.
        ethDelta = buy ? ethBefore - trader.balance : trader.balance - ethBefore;
        inferaDelta = buy ? token.balanceOf(trader) - inferaBefore : inferaBefore - token.balanceOf(trader);
    }

    function _trader(string memory name) internal returns (address t) {
        t = makeAddr(name);
        vm.deal(t, 10_000 ether);
        token.mint(t, 10_000 ether);
        vm.prank(t);
        token.approve(address(swapRouter), type(uint256).max);
    }

    function _capFired() internal returns (bool) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == CAP_EVENT) return true;
        }
        return false;
    }

    function _accrued() internal view returns (uint256[4] memory a) {
        for (uint256 i; i < 4; ++i) {
            a[i] = hook.accrued(i);
        }
    }

    function _sum(uint256[4] memory a) internal pure returns (uint256) {
        return a[0] + a[1] + a[2] + a[3];
    }

    function _diff(uint256[4] memory afterA, uint256[4] memory beforeA) internal pure returns (uint256[4] memory d) {
        for (uint256 i; i < 4; ++i) {
            d[i] = afterA[i] - beforeA[i];
        }
    }

    function _assertBacked() internal view {
        assertEq(address(hook).balance, _sum(_accrued()), "accrued fees are exactly backed by the hook's ETH");
        assertEq(token.balanceOf(address(hook)), 0, "the hook never keeps INFERA");
        for (uint256 i; i < 4; ++i) {
            uint256 inflow = hook.collected(i) + (i == BUYBACKS ? hook.withheldEth() : 0);
            assertEq(inflow, hook.accrued(i) + hook.released(i), "collected + withheld == accrued + released");
        }
    }

    function _assertRatesOfGross(uint256[4] memory fees, uint256 gross) internal pure {
        uint256 inferaFee = fees[TEAM] + fees[BUYBACKS] + fees[COMPUTE];
        assertApproxEqAbs(inferaFee, gross * 200 / 10_000, 1, "Infera takes 2% of the gross ETH leg");
        assertGe(fees[PROG], gross * 30 / 10_000, "Programmable takes at least 0.3% of the gross ETH leg");
        assertLe(fees[PROG], gross * 30 / 10_000 + 1, "Programmable's 0.3% is rounded up by at most 1 wei");
        assertEq(fees[TEAM], inferaFee / 2, "team is 1%");
        assertEq(fees[BUYBACKS], inferaFee / 4, "buybacks is 0.5%");
        assertEq(fees[COMPUTE], inferaFee - inferaFee / 2 - inferaFee / 4, "compute is 0.5% and takes the dust");
    }

    // ------------------------------------------------------------ the four swap shapes

    function test_exactInputBuy_takes2point3PercentOfTheEthPaid() public {
        uint256 ethBefore = address(this).balance;
        uint256 inferaBefore = token.balanceOf(address(this));
        _swap(true, -1 ether, 1 ether);

        assertEq(ethBefore - address(this).balance, 1 ether, "trader pays exactly 1 ETH");
        assertGt(token.balanceOf(address(this)), inferaBefore, "trader receives INFERA");
        uint256[4] memory a = _accrued();
        assertEq(a[TEAM], 0.01 ether, "team 1%");
        assertEq(a[BUYBACKS], 0.005 ether, "buybacks 0.5%");
        assertEq(a[COMPUTE], 0.005 ether, "compute 0.5%");
        assertEq(a[PROG], 0.003 ether, "Programmable 0.3%");
        assertEq(token.balanceOf(address(hook)), 0, "no INFERA is ever taken");
        _assertBacked();
    }

    function test_exactInputSell_takesFeesFromTheEthPaidOut() public {
        _swap(true, -5 ether, 5 ether); // give the trader INFERA to sell
        vm.roll(block.number + 1); // measure a block's first swap: the block-start price cap is idle
        uint256[4] memory before = _accrued();
        uint256 ethBefore = address(this).balance;

        _swap(false, -1 ether, 0); // sell exactly 1 INFERA

        uint256 received = address(this).balance - ethBefore;
        uint256[4] memory fees = _diff(_accrued(), before);
        uint256 gross = received + _sum(fees);
        assertEq(abi.encode(fees), abi.encode(hook.quoteFromGross(gross)), "fees are the gross-leg quote");
        _assertRatesOfGross(fees, gross);
        assertEq(token.balanceOf(address(hook)), 0, "fees are taken in ETH, never INFERA");
        _assertBacked();
    }

    function test_exactOutputBuy_traderPaysTheFeesOnTop() public {
        uint256 ethBefore = address(this).balance;
        uint256 inferaBefore = token.balanceOf(address(this));

        _swap(true, 0.5 ether, 2 ether); // receive exactly 0.5 INFERA

        assertEq(token.balanceOf(address(this)) - inferaBefore, 0.5 ether, "trader receives exactly 0.5 INFERA");
        uint256 paid = ethBefore - address(this).balance;
        uint256[4] memory fees = _accrued();
        (uint256[4] memory quoted, uint256 gross) = hook.quoteFromNet(paid - _sum(fees));
        assertEq(abi.encode(fees), abi.encode(quoted), "fees are the net-leg quote");
        assertEq(gross, paid, "the gross leg is everything the buyer paid");
        _assertRatesOfGross(fees, gross);
        _assertBacked();
    }

    function test_exactOutputSell_traderReceivesExactlyTheEthAskedFor() public {
        _swap(true, -5 ether, 5 ether);
        vm.roll(block.number + 1);
        uint256[4] memory before = _accrued();
        uint256 ethBefore = address(this).balance;

        _swap(false, 0.5 ether, 0); // receive exactly 0.5 ETH

        assertEq(address(this).balance - ethBefore, 0.5 ether, "trader receives exactly 0.5 ETH");
        uint256[4] memory fees = _diff(_accrued(), before);
        (uint256[4] memory quoted, uint256 gross) = hook.quoteFromNet(0.5 ether);
        assertEq(abi.encode(fees), abi.encode(quoted), "fees are the net-leg quote");
        assertEq(gross, 0.5 ether + _sum(fees), "the gross leg is what the pool paid out");
        _assertRatesOfGross(fees, gross);
        _assertBacked();
    }

    function testFuzz_everySwapShape_chargesTheGrossRatesAndStaysBacked(uint256 amount, uint8 shape) public {
        amount = bound(amount, 1e6, 20 ether);
        shape = shape % 4;
        _swap(true, -10 ether, 10 ether); // inventory for sells
        vm.roll(block.number + 1);
        uint256[4] memory before = _accrued();
        uint256 ethBefore = address(this).balance;
        vm.recordLogs();

        if (shape == 0) _swap(true, -int256(amount), amount); // exact-in buy
        else if (shape == 1) _swap(false, -int256(amount), 0); // exact-in sell
        else if (shape == 2) _swap(true, int256(amount), 100 ether); // exact-out buy
        else _swap(false, int256(amount / 10), 0); // exact-out sell

        uint256[4] memory fees = _diff(_accrued(), before);
        uint256 ethMoved =
            address(this).balance > ethBefore ? address(this).balance - ethBefore : ethBefore - address(this).balance;
        // Buys: the trader paid the gross leg. Sells: the pool paid out the gross leg = received + fees.
        uint256 gross = (shape == 0 || shape == 2) ? ethMoved : ethMoved + _sum(fees);
        _assertRatesOfGross(fees, gross);
        _assertBacked();
        assertFalse(_capFired(), "a block's first swap is never held to the block-start price");
    }

    function test_dustSwap_neverChargesMoreThanTheLeg() public {
        uint256[4] memory fees = hook.quoteFromGross(1);
        assertLe(_sum(fees), 1);
        _swap(true, -100, 100);
        _assertBacked();
    }

    // ------------------------------------------------------------ anti-sandwich

    /// Front-run buy, victim buy, back-run sell. Returns the attacker's ETH out of the back-run and
    /// the ETH they put in. `nextBlock` runs the back-run in a later block, where the block-start price
    /// has moved to the post-victim price: the outcome an unguarded pool would give in-block.
    function _sandwichABuy(bool nextBlock) internal returns (uint256 ethBack, uint256 ethIn) {
        address attacker = _trader("attacker");
        address victim = _trader("victim");
        uint256 bought;
        (ethIn, bought) = _swapAs(attacker, poolKeyEthInfera, true, -30 ether, 0);
        _swapAs(victim, poolKeyEthInfera, true, -100 ether, 0);
        if (nextBlock) vm.roll(block.number + 1);
        (ethBack,) = _swapAs(attacker, poolKeyEthInfera, false, -int256(bought), 0);
    }

    function test_sandwichingABuyLosesMoneyInOneBlock() public {
        uint256 snapshot = vm.snapshotState();
        (uint256 unguardedBack, uint256 ethIn) = _sandwichABuy(true);
        assertGt(unguardedBack, ethIn, "without the guard this sandwich clears the 2.3% fees and profits");
        vm.revertToState(snapshot);

        uint256 progBefore = hook.accrued(PROG);
        vm.recordLogs();
        (uint256 ethBack,) = _sandwichABuy(false);
        assertTrue(_capFired());
        assertLt(ethBack, ethIn, "in one block the back-run exits at the opening price and loses");
        assertGt(hook.withheldEth(), 0, "the back-run's withheld ETH was booked");
        assertGe(hook.accrued(BUYBACKS), hook.withheldEth(), "and it sits in the buybacks bucket");
        assertGt(hook.accrued(PROG), progBefore, "Programmable is still paid on every leg");
        assertEq(token.balanceOf(address(hook)), 0);
        _assertBacked();
    }

    function _sandwichASell(bool nextBlock) internal returns (uint256 inferaBack, uint256 inferaIn) {
        address attacker = _trader("attacker");
        address victim = _trader("victim");
        uint256 ethGot;
        (ethGot, inferaIn) = _swapAs(attacker, poolKeyEthInfera, false, -30 ether, 0);
        _swapAs(victim, poolKeyEthInfera, false, -100 ether, 0);
        if (nextBlock) vm.roll(block.number + 1);
        (, inferaBack) = _swapAs(attacker, poolKeyEthInfera, true, -int256(ethGot), 0);
    }

    function test_sandwichingASellLosesMoneyInOneBlock() public {
        uint256 snapshot = vm.snapshotState();
        (uint256 unguardedBack, uint256 inferaIn) = _sandwichASell(true);
        assertGt(unguardedBack, inferaIn, "without the guard this sandwich profits");
        vm.revertToState(snapshot);

        (uint256 inferaBack,) = _sandwichASell(false);
        assertLt(inferaBack, inferaIn, "in one block the back-run buys at the opening price and loses");
        assertGt(hook.withheldInfera(), 0, "the back-run's withheld INFERA was booked");
        assertEq(token.balanceOf(buybacks), hook.withheldInfera(), "and sent to the buybacks recipient");
        _assertBacked();
    }

    /// Audit finding 1 (JIT liquidity): the sandwich from _sandwichABuy, but before the back-run the
    /// attacker adds a large concentrated position around the current price and removes it after.
    /// Returns the attacker's whole-sequence profit in wei of ETH, valuing leftover INFERA at the
    /// final pool price.
    function _jitSandwichABuy() internal returns (int256 profitWei) {
        address attacker = _trader("jitAttacker");
        token.mint(attacker, 100_000 ether);
        vm.deal(attacker, 100_000 ether);
        vm.prank(attacker);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        address victim = _trader("victim");
        uint256 eth0 = attacker.balance;
        uint256 infera0 = token.balanceOf(attacker);

        (, uint256 bought) = _swapAs(attacker, poolKeyEthInfera, true, -30 ether, 0);
        _swapAs(victim, poolKeyEthInfera, true, -100 ether, 0);

        (, int24 tick,,) = StateLibrary.getSlot0(manager, poolKeyEthInfera.toId());
        int24 lower = (tick / 60) * 60 - 600;
        ModifyLiquidityParams memory jit = ModifyLiquidityParams({
            tickLower: lower, tickUpper: lower + 1200, liquidityDelta: 20_000 ether, salt: bytes32("jit")
        });
        vm.prank(attacker);
        modifyLiquidityRouter.modifyLiquidity{value: 50_000 ether}(poolKeyEthInfera, jit, ZERO_BYTES);
        _swapAs(attacker, poolKeyEthInfera, false, -int256(bought), 0);
        jit.liquidityDelta = -20_000 ether;
        vm.prank(attacker);
        modifyLiquidityRouter.modifyLiquidity(poolKeyEthInfera, jit, ZERO_BYTES);

        int256 ethDelta = int256(attacker.balance) - int256(eth0);
        int256 inferaDelta = int256(token.balanceOf(attacker)) - int256(infera0);
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, poolKeyEthInfera.toId());
        uint256 inferaValue = FullMath.mulDiv(
            FullMath.mulDiv(
                inferaDelta < 0 ? uint256(-inferaDelta) : uint256(inferaDelta), FixedPoint96.Q96, sqrtPriceX96
            ),
            FixedPoint96.Q96,
            sqrtPriceX96
        );
        profitWei = ethDelta + (inferaDelta < 0 ? -int256(inferaValue) : int256(inferaValue));
        emit log_named_int("JIT sandwich profit (wei)", profitWei);
    }

    function test_jitLiquidityCannotRecaptureWhatTheGuardWithholds() public {
        assertLt(_jitSandwichABuy(), 0, "a JIT-backed same-block sandwich must still lose money");
    }

    function testFuzz_noSameBlockSwapBeatsTheOpeningPrice(uint256 first, uint256 second, uint8 shape) public {
        first = bound(first, 1 ether, 100 ether);
        second = bound(second, 0.01 ether, 50 ether);
        shape = shape % 4;
        address trader = _trader("trader");
        // Move the price in the second trader's favour first.
        bool secondBuys = shape == 0 || shape == 2;
        _swapAs(_trader("mover"), poolKeyEthInfera, !secondBuys, -int256(first), 0);

        bool exactIn = shape < 2;
        (uint256 eth, uint256 infera) =
            _swapAs(trader, poolKeyEthInfera, secondBuys, exactIn ? -int256(second) : int256(second), 0);
        // At the 1:1 opening price, the pool leg of any trade is at best 1 ETH per INFERA: before fees a
        // buyer gets at most the ETH swapped in INFERA, and a seller at most the INFERA sold in ETH.
        if (secondBuys) assertLe(infera, eth + 1, "buyer got more INFERA than the opening price allows");
        else assertLe(eth, infera + 1, "seller got more ETH than the opening price allows");
        _assertBacked();
        assertEq(token.balanceOf(address(hook)), 0);
    }

    function test_theNextBlockReanchorsAtTheNewPrice() public {
        _swap(true, -50 ether, 50 ether);
        (uint48 blockNumber, uint160 anchored) = hook.blockStart();
        assertEq(blockNumber, block.number);
        assertEq(anchored, SQRT_PRICE_1_1, "anchored at the price the block opened with");
        vm.roll(block.number + 1);
        (uint160 now_,,,) = StateLibrary.getSlot0(manager, poolKeyEthInfera.toId());
        _swap(false, -1 ether, 0);
        (, anchored) = hook.blockStart();
        assertEq(anchored, now_);
    }

    /// A second hook/pool whose liquidity has a gap, so a capped swap can end with none in range.
    function _gappedPool(int24 lower, int24 upper) internal returns (InferaEthHook gapped, PoolKey memory key) {
        address at = address(uint160(InferaEthConfig.HOOK_FLAGS) | (uint160(0x6666) << 144));
        deployCodeTo(
            "InferaEthHook.sol:InferaEthHook",
            abi.encode(manager, address(token), uint24(3000), int24(60), owner, team, buybacks, compute),
            at
        );
        gapped = InferaEthHook(payable(at));
        key = gapped.poolKey();
        manager.initialize(key, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity{value: 100 ether}(
            key,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 100 ether, salt: 0}),
            ZERO_BYTES
        );
        modifyLiquidityRouter.modifyLiquidity{value: 100 ether}(
            key,
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: 100 ether, salt: 0}),
            ZERO_BYTES
        );
    }

    function test_withNoLiquidityInRange_withheldInferaGoesToTheBuybacksRecipient() public {
        (InferaEthHook gapped, PoolKey memory key) = _gappedPool(1200, 1800);
        // A sell pushes the price up into the upper range; then a buy, better than the opening price,
        // runs down out of it and stops in the empty gap.
        _swapAs(_trader("mover"), key, false, -1_000 ether, TickMath.getSqrtPriceAtTick(1500));
        _swapAs(_trader("buyer"), key, true, -1_000 ether, TickMath.getSqrtPriceAtTick(900));
        assertEq(StateLibrary.getLiquidity(manager, key.toId()), 0, "the swap ended with no liquidity in range");
        assertGt(token.balanceOf(buybacks), 0, "the withheld INFERA went to the buybacks recipient");
        assertEq(token.balanceOf(address(gapped)), 0);
    }

    function test_withNoLiquidityInRange_withheldEthAccruesToBuybacks() public {
        (InferaEthHook gapped, PoolKey memory key) = _gappedPool(-1800, -1200);
        _swapAs(_trader("mover"), key, true, -1_000 ether, TickMath.getSqrtPriceAtTick(-1500));
        uint256[4] memory before;
        for (uint256 i; i < 4; ++i) {
            before[i] = gapped.accrued(i);
        }
        _swapAs(_trader("seller"), key, false, -1_000 ether, TickMath.getSqrtPriceAtTick(-900));
        assertEq(StateLibrary.getLiquidity(manager, key.toId()), 0);
        uint256 buybacksGain = gapped.accrued(BUYBACKS) - before[BUYBACKS];
        uint256 teamGain = gapped.accrued(TEAM) - before[TEAM];
        assertGt(buybacksGain, teamGain / 2, "buybacks got its 0.5% plus the withheld ETH");
        uint256 total;
        for (uint256 i; i < 4; ++i) {
            total += gapped.accrued(i);
        }
        assertEq(address(gapped).balance, total, "still fully backed");
    }

    // ------------------------------------------------------------ payouts

    function test_anyoneCanReleaseAndFundsOnlyGoToTheRecipients() public {
        _swap(true, -1 ether, 1 ether);
        vm.prank(makeAddr("stranger"));
        hook.releaseAll();

        assertEq(team.balance, 0.01 ether);
        assertEq(buybacks.balance, 0.005 ether);
        assertEq(compute.balance, 0.005 ether);
        assertEq(PROGRAMMABLE.balance, 0.003 ether);
        assertEq(address(hook).balance, 0);
        assertEq(_sum(_accrued()), 0);
        assertEq(hook.collected(PROG), 0.003 ether, "lifetime totals are kept");
    }

    function test_aRecipientThatRejectsEtherOnlyBlocksItsOwnBucket() public {
        address rejector = address(new RejectsEther());
        vm.prank(owner);
        hook.setRecipient(InferaEthHook.Bucket.Team, rejector);
        _swap(true, -1 ether, 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                InferaEthHook.ReleaseFailed.selector, InferaEthHook.Bucket.Team, rejector, 0.01 ether
            )
        );
        hook.release(InferaEthHook.Bucket.Team);
        assertEq(hook.accrued(TEAM), 0.01 ether, "the failed bucket keeps its ETH");

        hook.releaseAll();
        assertEq(PROGRAMMABLE.balance, 0.003 ether, "releaseAll still pays the other buckets");
        assertEq(buybacks.balance, 0.005 ether);
        assertEq(compute.balance, 0.005 ether);
        assertEq(hook.accrued(TEAM), 0.01 ether, "the rejected bucket stays accrued");
        _assertBacked();
        _swap(false, -0.5 ether, 0); // and swaps keep working

        vm.prank(owner);
        hook.setRecipient(InferaEthHook.Bucket.Team, team);
        hook.release(InferaEthHook.Bucket.Team);
        assertGe(team.balance, 0.01 ether, "a fixed recipient gets the held ETH");
    }

    // ------------------------------------------------------------ owner controls

    function test_ownerIsTheConstructorArgumentEvenUnderCreate2FromAContract() public {
        HookFactory factory = new HookFactory();
        bytes memory args = abi.encode(manager, address(token), uint24(500), int24(10), owner, team, buybacks, compute);
        (uint256 salt, address predicted) =
            HookMiner.find(address(factory), InferaEthConfig.HOOK_FLAGS, type(InferaEthHook).creationCode, args);
        address deployed = factory.deploy(bytes32(salt), args);
        assertEq(deployed, predicted);
        assertEq(InferaEthHook(payable(deployed)).owner(), owner, "owner is the argument, never the factory");
    }

    function test_onlyTheOwnerChangesInferaRecipients_andNeverProgrammables() public {
        address newTeam = makeAddr("newTeam");
        vm.expectRevert(InferaEthHook.NotOwner.selector);
        hook.setRecipient(InferaEthHook.Bucket.Team, newTeam);

        vm.startPrank(owner);
        vm.expectRevert(InferaEthHook.ProgrammableRecipientIsFixed.selector);
        hook.setRecipient(InferaEthHook.Bucket.Programmable, newTeam);
        vm.expectRevert(InferaEthHook.ZeroAddress.selector);
        hook.setRecipient(InferaEthHook.Bucket.Team, address(0));
        hook.setRecipient(InferaEthHook.Bucket.Team, newTeam);
        vm.stopPrank();

        assertEq(hook.teamRecipient(), newTeam);
        assertEq(hook.recipientOf(InferaEthHook.Bucket.Programmable), PROGRAMMABLE);
    }

    function test_ownershipTransferIsTwoStep() public {
        address next = makeAddr("next");
        vm.prank(owner);
        hook.transferOwnership(next);
        assertEq(hook.owner(), owner, "nothing changes until accepted");
        vm.expectRevert(InferaEthHook.NotPendingOwner.selector);
        hook.acceptOwnership();
        vm.prank(next);
        hook.acceptOwnership();
        assertEq(hook.owner(), next);
    }

    // ------------------------------------------------------------ safety

    function test_otherPoolsUsingThisHookCannotSwap() public {
        PoolKey memory other = poolKeyEthInfera;
        other.fee = 500;
        other.tickSpacing = 10;
        manager.initialize(other, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity{value: 10 ether}(
            other,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 10 ether, salt: 0}),
            ZERO_BYTES
        );
        vm.expectRevert();
        swapRouter.swap{value: 0.1 ether}(
            other,
            SwapParams({zeroForOne: true, amountSpecified: -0.1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    function test_onlyThePoolManagerCanCallTheSwapCallbacks() public {
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});
        vm.expectRevert(InferaEthHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), poolKeyEthInfera, params, ZERO_BYTES);
    }

    function test_theHookRejectsEtherFromAnyoneButThePoolManager() public {
        (bool ok,) = address(hook).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function test_deployingAtAnAddressWithoutTheExactPermissionBitsReverts() public {
        address wrong = address(uint160(Hooks.BEFORE_SWAP_FLAG) | (uint160(0x5555) << 144));
        vm.expectRevert();
        deployCodeTo(
            "InferaEthHook.sol:InferaEthHook",
            abi.encode(manager, address(token), uint24(3000), int24(60), owner, team, buybacks, compute),
            wrong
        );
    }

    function test_constantsMatchProgrammablesEthereumRequirement() public view {
        assertEq(hook.PROGRAMMABLE_BPS(), 30);
        assertEq(hook.PROGRAMMABLE_RECIPIENT(), PROGRAMMABLE);
        assertEq(hook.INFERA_BPS(), 200);
        assertEq(hook.TOTAL_BPS(), 230);
    }

    // ------------------------------------------------------------ audit follow-ups

    /// Audit finding 3: the block's first swap sets the anchor. An attacker who takes that slot anchors
    /// the block at the price before their own trade, so their round trip is still held to it.
    function test_attackerHoldingTheBlocksFirstSwapIsHeldToThePriceBeforeIt() public {
        address attacker = _trader("attacker");
        (uint160 openPrice,,,) = StateLibrary.getSlot0(manager, poolKeyEthInfera.toId());
        (uint256 paid, uint256 bought) = _swapAs(attacker, poolKeyEthInfera, true, -50 ether, 0);
        (, uint160 anchored) = hook.blockStart();
        assertEq(anchored, openPrice, "the anchor is the price before the attacker's own first swap");
        _swapAs(_trader("victim"), poolKeyEthInfera, true, -100 ether, 0);
        (uint256 back,) = _swapAs(attacker, poolKeyEthInfera, false, -int256(bought), 0);
        assertLt(back, paid, "the round trip around a victim still loses");
        _assertBacked();
    }

    /// Audit finding 2, pinned so the documentation stays honest: a sandwich whose back-run lands in a
    /// later block is not prevented.
    function test_crossBlockSandwichIsNotPrevented_knownLimitation() public {
        (uint256 back, uint256 ethIn) = _sandwichABuy(true);
        assertGt(back, ethIn, "known limitation: the next-block back-run still profits");
    }

    function testFuzz_exactOutputBuyAfterAFavourableMove_accountsExactly(uint256 move, uint256 want) public {
        move = bound(move, 1 ether, 100 ether);
        want = bound(want, 0.01 ether, 50 ether);
        // A sell first makes INFERA cheaper than the 1:1 opening price for the buyer that follows.
        _swapAs(_trader("mover"), poolKeyEthInfera, false, -int256(move), 0);
        uint256[4] memory before = _accrued();
        uint256 withheldBefore = hook.withheldEth();

        (uint256 paid, uint256 got) = _swapAs(_trader("buyer"), poolKeyEthInfera, true, int256(want), 0);

        assertEq(got, want, "the buyer receives exactly what they asked for");
        uint256 withheld = hook.withheldEth() - withheldBefore;
        uint256 fees = _sum(_diff(_accrued(), before)) - withheld;
        assertGe(paid - fees, want, "the swap itself cost at least the opening price (1 ETH per INFERA)");
        (uint256[4] memory quoted, uint256 gross) = hook.quoteFromNet(paid - fees);
        assertEq(_sum(quoted), fees, "fees are the net-leg quote of the price-enforced cost");
        assertEq(gross, paid, "the gross leg is everything the buyer paid");
        _assertBacked();
    }

    function testFuzz_quotesNeverOverchargeOrShortProgrammable(uint256 amount) public view {
        amount = bound(amount, 1, type(uint128).max);
        uint256[4] memory fees = hook.quoteFromGross(amount);
        assertLe(_sum(fees), amount, "never more than the leg");
        if (amount >= 1_000) {
            assertGe(fees[PROG] * 10_000, amount * 30, "Programmable gets at least 0.3%");
            assertApproxEqAbs(fees[TEAM] + fees[BUYBACKS] + fees[COMPUTE], amount * 200 / 10_000, 1);
        }
        (uint256[4] memory netFees, uint256 gross) = hook.quoteFromNet(amount);
        assertEq(gross - amount, _sum(netFees), "net quote: gross = net + fees");
        assertGe(netFees[PROG] * 10_000, gross * 30, "Programmable gets at least 0.3% of the gross leg");
    }

    /// Exact-input buy fees are taken from the PoolManager's ETH before the buyer settles, so a fee
    /// can be at most the native ETH the PoolManager holds (about 55,000 ETH on Mainnet on 2026-11-11).
    function _whale() internal returns (address whale) {
        whale = makeAddr("whale");
        vm.deal(whale, 1e30);
        token.mint(whale, 1e30);
        vm.prank(whale);
        token.approve(address(swapRouter), type(uint256).max);
    }

    function _whaleBuy(address whale, uint256 amount) internal {
        vm.prank(whale);
        swapRouter.swap{value: amount}(
            poolKeyEthInfera,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    function test_extremeAmountsSwapAndStayConsistent() public {
        address whale = _whale();
        vm.deal(address(manager), address(manager).balance + 55_000 ether); // Mainnet-like native ETH
        _whaleBuy(whale, 1_000_000 ether);
        assertEq(hook.accrued(PROG), 3_000 ether, "0.3% of a 1,000,000 ETH buy");
        vm.roll(block.number + 1);
        _swapAs(whale, poolKeyEthInfera, false, -1e27, 0);
        _assertBacked();
    }

    function test_aBuyWhoseFeeExceedsThePoolManagersEthRevertsWhole() public {
        address whale = _whale();
        uint256 managerEth = address(manager).balance;
        uint256 tooBig = managerEth * 10_000 / 230 + 1 ether; // 2.3% of it is more than the PoolManager holds
        vm.expectRevert();
        _whaleBuy(whale, tooBig);
        assertEq(_sum(_accrued()), 0, "nothing was charged");
        assertEq(address(manager).balance, managerEth);
    }

    function test_zeroAmountSwapsRevert_andOneWeiSwapsStayConsistent() public {
        vm.expectRevert();
        _swap(true, 0, 0);
        _swap(true, -1, 1);
        _swap(true, 1, 10);
        _swap(false, -1, 0);
        _swap(false, 1, 0);
        _assertBacked();
    }

    function test_aReentrantRecipientIsPaidExactlyOnce() public {
        ReentrantRecipient r = new ReentrantRecipient(true);
        r.setHook(hook);
        vm.prank(owner);
        hook.setRecipient(InferaEthHook.Bucket.Team, address(r));
        _swap(true, -1 ether, 1 ether);

        hook.releaseAll();

        assertEq(address(r).balance, 0.01 ether, "paid its 1% once");
        assertEq(r.calls(), 1, "its re-entry was refused");
        assertEq(hook.accrued(TEAM), 0);
        _assertBacked();
    }

    function test_aRecipientThatRevertsOnReentryKeepsItsBalance() public {
        ReentrantRecipient r = new ReentrantRecipient(false);
        r.setHook(hook);
        vm.prank(owner);
        hook.setRecipient(InferaEthHook.Bucket.Team, address(r));
        _swap(true, -1 ether, 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                InferaEthHook.ReleaseFailed.selector, InferaEthHook.Bucket.Team, address(r), 0.01 ether
            )
        );
        hook.release(InferaEthHook.Bucket.Team);
        hook.releaseAll();

        assertEq(hook.accrued(TEAM), 0.01 ether, "nothing left the bucket");
        assertEq(address(r).balance, 0);
        _assertBacked();
    }

    function test_changingARecipientSendsItsUnpaidBalanceToTheNewOne() public {
        _swap(true, -1 ether, 1 ether);
        address newTeam = makeAddr("newTeam");
        vm.prank(owner);
        hook.setRecipient(InferaEthHook.Bucket.Team, newTeam);
        hook.release(InferaEthHook.Bucket.Team);
        assertEq(newTeam.balance, 0.01 ether, "documented: unpaid balance follows the recipient");
        assertEq(team.balance, 0);
    }

    function test_withdrawingLiquidityLeavesHookAccountingUntouched() public {
        _sandwichABuy(false); // fees and withheld ETH both booked
        uint256[4] memory before = _accrued();
        uint256 withheldEthBefore = hook.withheldEth();
        uint256 balanceBefore = address(hook).balance;

        modifyLiquidityRouter.modifyLiquidity(
            poolKeyEthInfera,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: -400 ether,
                salt: 0
            }),
            ZERO_BYTES
        );

        assertEq(abi.encode(_accrued()), abi.encode(before));
        assertEq(hook.withheldEth(), withheldEthBefore);
        assertEq(address(hook).balance, balanceBefore);
        vm.roll(block.number + 1);
        _swap(true, -0.1 ether, 0.1 ether); // trading continues on the remaining liquidity
        _assertBacked();
    }

    function test_aTaxedTokenFailsSafely() public {
        TaxableToken taxed = new TaxableToken();
        taxed.mint(address(this), 1_000_000 ether);
        taxed.approve(address(swapRouter), type(uint256).max);
        taxed.approve(address(modifyLiquidityRouter), type(uint256).max);
        address at = address(uint160(InferaEthConfig.HOOK_FLAGS) | (uint160(0x7777) << 144));
        deployCodeTo(
            "InferaEthHook.sol:InferaEthHook",
            abi.encode(manager, address(taxed), uint24(3000), int24(60), owner, team, buybacks, compute),
            at
        );
        InferaEthHook taxedHook = InferaEthHook(payable(at));
        PoolKey memory key = taxedHook.poolKey();
        manager.initialize(key, SQRT_PRICE_1_1);
        ModifyLiquidityParams memory full = ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(60),
            tickUpper: TickMath.maxUsableTick(60),
            liquidityDelta: 100 ether,
            salt: 0
        });
        modifyLiquidityRouter.modifyLiquidity{value: 200 ether}(key, full, ZERO_BYTES);

        taxed.setTax(true);
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        // The PoolManager receives less than it is owed, so anything paying in the token reverts whole.
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity{value: 200 ether}(key, full, ZERO_BYTES);
        vm.expectRevert();
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            settings,
            ZERO_BYTES
        );
        // Buys still settle (the token taxes what the buyer receives); the hook's ETH stays exactly backed.
        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            settings,
            ZERO_BYTES
        );
        uint256 owed;
        for (uint256 i; i < 4; ++i) {
            owed += taxedHook.accrued(i);
        }
        assertEq(address(taxedHook).balance, owed);
        assertEq(taxed.balanceOf(address(taxedHook)), 0);
    }

    function test_deployingOnMainnetWithANonCanonicalPoolManagerReverts() public {
        vm.chainId(1);
        address at = address(uint160(InferaEthConfig.HOOK_FLAGS) | (uint160(0x8888) << 144));
        vm.expectRevert(InferaEthHook.WrongPoolManager.selector);
        deployCodeTo(
            "InferaEthHook.sol:InferaEthHook",
            abi.encode(manager, address(token), uint24(3000), int24(60), owner, team, buybacks, compute),
            at
        );
    }

    /// Known behaviour: an exact-input buy whose own price limit stops it early still pays fees on
    /// the full amount specified. v4 only lets a hook take the specified currency (ETH here) in
    /// beforeSwap, before the fill size is known. Routers normally set no binding limit.
    function test_partialFillAtAPriceLimit_paysFeesOnTheAmountSpecified_knownBehaviour() public {
        uint160 limit = TickMath.getSqrtPriceAtTick(-600); // about 6% below the opening price
        uint256 ethBefore = address(this).balance;
        swapRouter.swap{value: 100 ether}(
            poolKeyEthInfera,
            SwapParams({zeroForOne: true, amountSpecified: -100 ether, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
        uint256 paid = ethBefore - address(this).balance;
        assertLt(paid, 100 ether, "the swap stopped at the limit and the unused ETH came back");
        assertEq(abi.encode(_accrued()), abi.encode(hook.quoteFromGross(100 ether)), "fees on the full 100 ETH");
        _assertBacked();
    }
}
