// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {InferaEthHook} from "../src/InferaEthHook.sol";
import {InferaEthConfig} from "../src/InferaEthConfig.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";

/// @notice Deploys InferaEthHook at a CREATE2 address carrying exactly its permission bits.
/// @dev Takes everything as arguments and reads no environment variables. The signer comes from
///      Foundry's own wallet options (`--account`, `--ledger`, ...), never a key in a file:
///
///      forge script script/DeployInferaEthHook.s.sol --sig "run(address,address)" <INFERA> <OWNER> \
///        --rpc-url <RPC> --account <keystore-name> --broadcast
///
///      On Ethereum Mainnet it uses the canonical PoolManager; `run(address,address,address)` takes
///      one explicitly for testnets and local nodes. A Programmable Custom Launch deploys the hook
///      through their Launch Stamp Router instead: mine its salt with MineHookSalt.s.sol.
contract DeployInferaEthHook is Script {
    function run(address infera, address owner) external returns (InferaEthHook) {
        require(block.chainid == InferaEthConfig.CHAIN_ID, "pass the PoolManager off Ethereum Mainnet");
        return run(IPoolManager(InferaEthConfig.POOL_MANAGER), infera, owner);
    }

    function run(IPoolManager manager, address infera, address owner) public returns (InferaEthHook hook) {
        require(address(manager).code.length > 0, "no PoolManager at that address");
        require(infera.code.length > 0, "no INFERA token at that address");
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
        (uint256 salt, address predicted) = HookMiner.find(
            InferaEthConfig.CREATE2_DEPLOYER, InferaEthConfig.HOOK_FLAGS, type(InferaEthHook).creationCode, args
        );

        vm.startBroadcast();
        hook = new InferaEthHook{salt: bytes32(salt)}(
            manager,
            infera,
            InferaEthConfig.LP_FEE,
            InferaEthConfig.TICK_SPACING,
            owner,
            InferaEthConfig.TEAM_RECIPIENT,
            InferaEthConfig.BUYBACKS_RECIPIENT,
            InferaEthConfig.COMPUTE_RECIPIENT
        );
        vm.stopBroadcast();

        require(address(hook) == predicted, "hook landed at an unexpected address");
        require(hook.owner() == owner, "owner mismatch");
        PoolKey memory key = hook.poolKey();
        console2.log("InferaEthHook:", address(hook));
        console2.log("salt:", salt);
        console2.log("owner:", owner);
        console2.log("pool fee / tick spacing:", key.fee, uint256(int256(key.tickSpacing)));
        console2.logBytes32(PoolId.unwrap(hook.poolId()));
    }
}
