// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {ShortfallV2Commitments} from "../../verification/ShortfallV2Commitments.sol";

/// @notice Non-exclusive V2 prepared-operation registry.
/// @dev Prepared operations freeze identity only; they reserve zero capital and
/// do not establish a global Shortfall mutex.
contract SourceBoundProRataControllerV2 {
    enum State { None, Prepared, Abandoned }

    struct PreparedOperation {
        bytes32 root;
        address initiator;
        bytes32 operationId;
    }

    mapping(bytes32 => State) public state;
    mapping(bytes32 => bytes32) public preparedOperationRoot;
    mapping(bytes32 => address) public preparedInitiator;

    error InvalidOperation();
    error OperationAlreadyExists(bytes32 operationId);
    error OnlyInitiator(address caller);
    error InvalidState(State actual);

    event OperationPrepared(bytes32 indexed operationId, bytes32 indexed preparedRoot, address indexed initiator);
    event OperationAbandoned(bytes32 indexed operationId, bytes32 indexed preparedRoot);

    function prepareOperation(ShortfallV2Commitments.PreparedOperation calldata operation)
        external returns (bytes32 root)
    {
        if (operation.operationId == bytes32(0) || operation.initiator == bytes32(0)) revert InvalidOperation();
        address initiator = address(uint160(uint256(operation.initiator)));
        if (initiator == address(0) || msg.sender != initiator) revert OnlyInitiator(msg.sender);
        if (state[operation.operationId] != State.None) revert OperationAlreadyExists(operation.operationId);
        root = ShortfallV2Commitments.preparedOperationRoot(operation);
        preparedOperationRoot[operation.operationId] = root;
        preparedInitiator[operation.operationId] = initiator;
        state[operation.operationId] = State.Prepared;
        emit OperationPrepared(operation.operationId, root, initiator);
    }

    function abandonPreparedOperation(bytes32 operationId) external {
        if (state[operationId] != State.Prepared) revert InvalidState(state[operationId]);
        if (msg.sender != preparedInitiator[operationId]) revert OnlyInitiator(msg.sender);
        state[operationId] = State.Abandoned;
        emit OperationAbandoned(operationId, preparedOperationRoot[operationId]);
    }
}
