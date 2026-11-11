// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {InferaEthHook} from "../../src/InferaEthHook.sol";

/// A Chainlink-style ETH/USD feed with a settable answer and age (8 decimals, like Chainlink's).
contract MockEthUsdFeed {
    uint8 public constant decimals = 8;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public round = 1;

    constructor(int256 answer_) {
        answer = answer_;
        updatedAt = block.timestamp;
    }

    function set(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
        ++round;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (round, answer, updatedAt, updatedAt, round);
    }
}

/// Stands in for the canonical Universal Router during launch protection: swaps like PoolSwapTest
/// and reports the buyer it was told to (the real router reports its caller).
contract ProtectedRouterMock is PoolSwapTest {
    address public msgSender;

    constructor(IPoolManager manager_) PoolSwapTest(manager_) {}

    function setMsgSender(address buyer) external {
        msgSender = buyer;
    }
}

library HookArgs {
    /// Constructor arguments for InferaEthHook with no extra opening-tax-exempt wallets.
    function encode(
        IPoolManager manager,
        address token,
        uint24 lpFee,
        int24 tickSpacing,
        address owner,
        address[3] memory teamBuybacksCompute,
        address initializer,
        address developer,
        address router
    ) internal view returns (bytes memory) {
        address[6] memory noExemptions;
        return abi.encode(
            manager,
            token,
            lpFee,
            tickSpacing,
            InferaEthHook.Recipients({
                owner: owner,
                team: teamBuybacksCompute[0],
                buybacks: teamBuybacksCompute[1],
                compute: teamBuybacksCompute[2]
            }),
            InferaEthHook.Protection({
                initializer: initializer,
                developer: developer,
                router: router,
                routerCodeHash: router.codehash,
                exemptWallets: noExemptions
            })
        );
    }
}
