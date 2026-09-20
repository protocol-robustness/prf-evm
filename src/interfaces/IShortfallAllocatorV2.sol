// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IShortfallAllocatorV2 {
    enum State { None, Created, Funded, Activated, Claims, Closed, Cancelled }

    struct Operation {
        State state;
        bytes32 allocationBindingRoot;
        bytes32 realizedStatementRoot;
        IERC20 token;
        uint256 amount;
        address residualRecipient;
    }

    function create(
        bytes32 operationId,
        bytes32 allocationBindingRoot,
        bytes32 realizedStatementRoot,
        IERC20 token,
        uint256 amount,
        address residualRecipient
    ) external;

    function fund(bytes32 operationId) external;
    function operation(bytes32 operationId) external view returns (Operation memory);
}
