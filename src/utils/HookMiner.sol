// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title HookMiner
/// @notice Finds and validates a CREATE2 salt whose resulting address carries exactly the required
///         Uniswap v4 hook permission flag bits. The hook requires `0xCC`
///         (beforeSwap | afterSwap | beforeSwapReturnDelta | afterSwapReturnDelta).
library HookMiner {
    uint256 internal constant MAX_ITERATIONS = 500_000;

    error NoSaltFound(uint160 flags);

    /// @notice Iterates salts until the predicted CREATE2 address satisfies `flags` under the mask.
    /// @param deployer The address that will execute the CREATE2 deployment.
    /// @param flags The exact flag bits required (for example 0xCC).
    /// @param creationCode The contract creation code.
    /// @param constructorArgs ABI-encoded constructor arguments.
    /// @return salt The salt to use.
    /// @return hookAddress The predicted address for that salt.
    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        pure
        returns (uint256 salt, address hookAddress)
    {
        // forge-lint: disable-next-line(encode-packed-collision) init code is creation code ++ args by definition
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));
        for (uint256 i = 0; i < MAX_ITERATIONS; ++i) {
            address candidate = computeCreate2Address(deployer, bytes32(i), initCodeHash);
            if (uint160(candidate) & 0x3FFF == flags) {
                return (i, candidate);
            }
        }
        revert NoSaltFound(flags);
    }

    /// @notice True when `hook` carries exactly `flags` in its low 14 bits.
    function validate(address hook, uint160 flags) internal pure returns (bool) {
        return uint160(hook) & 0x3FFF == flags;
    }

    /// @notice The standard CREATE2 address derivation.
    function computeCreate2Address(address deployer, bytes32 salt, bytes32 initCodeHash)
        internal
        pure
        returns (address)
    {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }
}
