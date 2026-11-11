// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {InferaEthHook} from "../src/InferaEthHook.sol";
import {InferaEthConfig} from "../src/InferaEthConfig.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";

/// @notice Prints a CREATE2 salt that puts InferaEthHook at an address carrying exactly its
///         permission bits, for whichever contract performs the CREATE2 (e.g. Programmable's
///         Launch Stamp Router, or Foundry's 0x4e59…956C deployer). Reads no environment variables:
///
///         forge script script/MineHookSalt.s.sol --sig "run(address,address,address,address)" \
///           <POOL_MANAGER> <INFERA> <OWNER> <CREATE2_DEPLOYER>
contract MineHookSalt is Script {
    function run(address manager, address infera, address owner, address deployer) external pure {
        bytes memory args = abi.encode(
            manager,
            infera,
            InferaEthConfig.LP_FEE,
            InferaEthConfig.TICK_SPACING,
            owner,
            InferaEthConfig.TEAM_RECIPIENT,
            InferaEthConfig.BUYBACKS_RECIPIENT,
            InferaEthConfig.COMPUTE_RECIPIENT
        );
        bytes memory creationCode = type(InferaEthHook).creationCode;
        (uint256 salt, address hook) = HookMiner.find(deployer, InferaEthConfig.HOOK_FLAGS, creationCode, args);
        console2.log("salt:", salt);
        console2.log("hook address:", hook);
        console2.log("init code (creation code ++ constructor args):");
        console2.logBytes(abi.encodePacked(creationCode, args));
    }
}
