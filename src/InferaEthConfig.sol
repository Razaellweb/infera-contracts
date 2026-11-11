// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title InferaEthConfig
/// @notice Ethereum Mainnet values for deploying InferaEthHook. The hook takes everything as
///         constructor arguments (so it is testable on a local PoolManager); scripts read these.
library InferaEthConfig {
    uint256 internal constant CHAIN_ID = 1;

    /// @dev Uniswap v4 PoolManager on Ethereum Mainnet.
    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    /// @dev Pool parameters: 0.3% static LP fee, tick spacing 60.
    uint24 internal constant LP_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;

    /// @dev Infera fee recipients.
    address internal constant TEAM_RECIPIENT = 0xBB4dEA1A372EBCA201c1cD140Cd21bC42E33095A;
    address internal constant BUYBACKS_RECIPIENT = 0x3835872Ea6EbE568769BabB3ba77147C4789A3FD;
    address internal constant COMPUTE_RECIPIENT = 0x4db6dF81fd2aDC898BF3af1D01E518E8ce23F83f;

    /// @dev Deterministic CREATE2 deployer Foundry routes `new X{salt: ...}` through in scripts.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @dev beforeSwap | afterSwap | beforeSwapReturnDelta | afterSwapReturnDelta.
    uint160 internal constant HOOK_FLAGS = (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2);
}
