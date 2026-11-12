// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {InferaEthHook} from "../src/InferaEthHook.sol";
import {InferaToken} from "../src/InferaToken.sol";
import {InferaLaunchInitializer} from "../src/InferaLaunchInitializer.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// Rehearses the exact packed Programmable request on an Ethereum Mainnet fork: each target is
/// deployed at the address Programmable's packer predicted, with the packer's resolved constructor
/// arguments, then Programmable's graph factory makes the packed initializer call with the packed
/// value. Needs `launch/build/pack-result.json` and the config from `launch/build.py` + `pack`
/// (skipped without them, or off a Mainnet fork). The bytecode is the same: build.py compiles the
/// same sources with the same settings, which `launch/README.md` shows how to check.
contract InferaLaunchPackageForkTest is Test {
    using stdJson for string;

    address constant GRAPH_FACTORY = 0xB012e4A8F2c5FC4E8E4faCA9D5Ad6FfF13FBA887;
    address constant ROUTER = 0xd92A36B0000531EF3063dEd4De20A0783308446C;
    address constant LAUNCH_WALLET = 0x1F9c16370fAdd58A05D87C685488Ef556d2DE7be;
    address constant PROGRAMMABLE = 0xD88539d3c4C460136a733A3Fd60cf6BF269079da;
    address constant TAX_EXEMPT = 0xeE076ee798f5E16F3FDaF7607473Ab1DC5Ee865E;

    function test_fork_thePackedLaunchRunsOnMainnet() public {
        string memory packPath = "launch/build/pack-result.json";
        if (block.chainid != 1 || !vm.exists(packPath)) {
            vm.skip(true);
            return;
        }
        string memory pack = vm.readFile(packPath);
        string memory config = vm.readFile("programmable-launch.config.json");

        address initializer = pack.readAddress(".predictions[0].predictedAddress");
        address token = pack.readAddress(".predictions[1].predictedAddress");
        address hook = pack.readAddress(".predictions[2].predictedAddress");
        assertEq(pack.readString(".predictions[0].targetId"), "initializer");
        assertEq(pack.readString(".predictions[1].targetId"), "token");
        assertEq(pack.readString(".predictions[2].targetId"), "hook");

        deployCodeTo(
            "InferaLaunchInitializer.sol:InferaLaunchInitializer",
            pack.readBytes(".predictions[0].resolvedConstructorArguments"),
            initializer
        );
        deployCodeTo(
            "InferaToken.sol:InferaToken", pack.readBytes(".predictions[1].resolvedConstructorArguments"), token
        );
        deployCodeTo(
            "InferaEthHook.sol:InferaEthHook", pack.readBytes(".predictions[2].resolvedConstructorArguments"), hook
        );

        // Everything is wired as packed.
        assertEq(InferaToken(token).initializer(), initializer);
        assertEq(InferaEthHook(payable(hook)).infera(), token);
        assertEq(InferaEthHook(payable(hook)).initializer(), initializer);
        assertEq(InferaEthHook(payable(hook)).developer(), LAUNCH_WALLET);
        assertEq(InferaEthHook(payable(hook)).owner(), LAUNCH_WALLET);
        assertEq(InferaEthHook(payable(hook)).router(), ROUTER);
        assertEq(InferaLaunchInitializer(initializer).launcher(), GRAPH_FACTORY);
        assertEq(InferaEthHook(payable(hook)).exemptWallets()[0], TAX_EXEMPT);
        assertTrue(InferaEthHook(payable(hook)).isOpeningTaxExempt(TAX_EXEMPT));
        assertTrue(InferaEthHook(payable(hook)).isOpeningTaxExempt(LAUNCH_WALLET));
        for (uint256 i = 1; i < 6; ++i) {
            assertEq(InferaEthHook(payable(hook)).exemptWallets()[i], address(0), "no other exemptions");
        }

        // The launch call, as Programmable's graph factory makes it. Keep the live price fresh.
        (,,, uint256 updatedAt,) = InferaLaunchInitializer(initializer).ethUsdFeed().latestRoundData();
        if (block.timestamp - updatedAt > 1 hours) vm.warp(updatedAt + 1);
        uint256 value = vm.parseUint(config.readString(".targets[0].initializerValueWei"));
        vm.deal(GRAPH_FACTORY, value);
        vm.prank(GRAPH_FACTORY);
        (bool ok, bytes memory reason) =
            initializer.call{value: value}(pack.readBytes(".predictions[0].resolvedInitializerCalldata"));
        if (!ok) {
            assembly {
                revert(add(reason, 32), mload(reason))
            }
        }

        uint256 fdv = InferaLaunchInitializer(initializer).openingFdvUsd();
        emit log_named_uint("opening FDV at the live price (USD)", fdv);
        assertGe(fdv, 15_000);
        uint256 developerBought = InferaToken(token).balanceOf(LAUNCH_WALLET);
        emit log_named_uint("developer's first buy (INFERA)", developerBought / 1 ether);
        assertGt(developerBought, 0);
        assertEq(InferaEthHook(payable(hook)).openingTaxAccrued(), 0, "the developer pays no opening tax");

        // A buyer in the opening seconds pays the opening tax through the canonical router.
        address alice = makeAddr("alice");
        vm.deal(alice, 1 ether);
        _universalRouterBuy(InferaEthHook(payable(hook)).poolKey(), alice, 0.01 ether);
        assertGt(InferaToken(token).balanceOf(alice), 0);
        assertGt(InferaEthHook(payable(hook)).openingTaxAccrued(), 0.009 ether, "about 96.7% opening tax");
        // The exempt wallet buys in the same opening seconds without the opening tax, within its 2%.
        uint256 taxBefore = InferaEthHook(payable(hook)).openingTaxAccrued();
        vm.deal(TAX_EXEMPT, 1 ether);
        _universalRouterBuy(InferaEthHook(payable(hook)).poolKey(), TAX_EXEMPT, 0.01 ether);
        assertGt(InferaToken(token).balanceOf(TAX_EXEMPT), 0);
        assertEq(InferaEthHook(payable(hook)).openingTaxAccrued(), taxBefore, "no opening tax for the exempt wallet");

        uint256 programmableBefore = PROGRAMMABLE.balance;
        InferaEthHook(payable(hook)).releaseAll();
        assertGt(PROGRAMMABLE.balance, programmableBefore);
        assertEq(hook.balance, 0);
    }

    function _universalRouterBuy(PoolKey memory key, address buyer, uint128 amountIn) internal {
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
}
