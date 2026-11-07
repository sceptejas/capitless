// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IExecutionAdapter} from "../interfaces/IExecutionAdapter.sol";

/// @title MockExecutionAdapter
/// @notice Test-only configurable adapter. Does not call PoolManager.
///         Used to test RFQExecutor validation logic independently of v4.
///
/// Capital-light model: returns actualRouteCost (USDC cost) and amountOut (WETH delivered).
/// Does NOT transfer tokens — caller must handle token setup in tests.
contract MockExecutionAdapter is IExecutionAdapter {
    uint256 public mockRouteCost;   // USDC consumed by the mock hedge
    uint256 public mockAmountOut;   // WETH "delivered" (reported, not actually transferred)
    bool    public shouldRevert;
    string  public revertMessage;
    address public executor;

    constructor(address _executor) {
        executor = _executor;
    }

    function configure(uint256 routeCost, uint256 amtOut) external {
        mockRouteCost = routeCost;
        mockAmountOut = amtOut;
        shouldRevert  = false;
    }

    function configureRevert(string calldata message) external {
        shouldRevert  = true;
        revertMessage = message;
    }

    function execute(ExecutionRequest calldata req)
        external
        returns (ExecutionResult memory result)
    {
        if (msg.sender != executor) revert NotExecutor(msg.sender);
        require(!shouldRevert, revertMessage);

        // Suppress unused param warning
        req;

        result = ExecutionResult({
            actualRouteCost: mockRouteCost,
            amountOut:       mockAmountOut
        });
    }
}
