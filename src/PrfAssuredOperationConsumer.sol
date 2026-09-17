// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {IPrfStatementAdmission} from "./interfaces/IPrfStatementAdmission.sol";

/// @title PrfAssuredOperationConsumer
/// @notice PRF EVM Assurance Admission/Consumption V1 reference consumer.
/// @dev Verification authority establishes the admitted assurance fact. This
///      application authority separately precommits an operation to the root,
///      applies local acceptance policy, and records one operation-scoped
///      consumption. It deliberately has no generic callback or asset-custody surface.
contract PrfAssuredOperationConsumer {
    bytes32 private constant CONSUMPTION_DOMAIN =
        keccak256("PRF_ASSURED_OPERATION_CONSUMPTION_V1");

    struct Operation {
        bool exists;
        bool applied;
        bytes32 expectedStatementRoot;
        bytes32 requiredConfigurationRoot;
        uint64 requiredConfigurationEpoch;
        bytes32 admissionReceiptId;
        bytes32 consumptionId;
    }

    IPrfStatementAdmission public immutable admission;
    address public immutable operationAuthority;

    mapping(bytes32 operationId => Operation) private _operations;
    mapping(bytes32 consumptionId => bool) public consumptionUsed;

    event OperationCreated(
        bytes32 indexed operationId,
        bytes32 indexed expectedStatementRoot,
        bytes32 requiredConfigurationRoot,
        uint64 requiredConfigurationEpoch
    );
    event OperationApplied(
        bytes32 indexed operationId,
        bytes32 indexed admissionReceiptId,
        bytes32 indexed consumptionId,
        bytes32 statementRoot
    );

    error OnlyOperationAuthority(address caller, address expected);
    error ZeroValue();
    error OperationAlreadyExists(bytes32 operationId);
    error UnknownOperation(bytes32 operationId);
    error OperationAlreadyApplied(bytes32 operationId);
    error UnknownAdmissionReceipt(bytes32 receiptId);
    error StatementRootMismatch(bytes32 expected, bytes32 actual);
    error ConfigurationRootMismatch(bytes32 expected, bytes32 actual);
    error ConfigurationEpochMismatch(uint64 expected, uint64 actual);
    error ConsumptionAlreadyUsed(bytes32 consumptionId);

    constructor(IPrfStatementAdmission admission_, address operationAuthority_) {
        if (address(admission_) == address(0) || operationAuthority_ == address(0)) {
            revert ZeroValue();
        }
        admission = admission_;
        operationAuthority = operationAuthority_;
    }

    /// @notice Precommit a pending operation to semantic and admission-acceptance inputs.
    /// @dev Operations are immutable after creation; there is intentionally no update path.
    function createOperation(
        bytes32 operationId,
        bytes32 expectedStatementRoot,
        bytes32 requiredConfigurationRoot,
        uint64 requiredConfigurationEpoch
    ) external {
        if (msg.sender != operationAuthority) {
            revert OnlyOperationAuthority(msg.sender, operationAuthority);
        }
        if (
            operationId == bytes32(0) ||
            expectedStatementRoot == bytes32(0) ||
            requiredConfigurationRoot == bytes32(0)
        ) revert ZeroValue();
        if (_operations[operationId].exists) revert OperationAlreadyExists(operationId);

        _operations[operationId].exists = true;
        _operations[operationId].expectedStatementRoot = expectedStatementRoot;
        _operations[operationId].requiredConfigurationRoot = requiredConfigurationRoot;
        _operations[operationId].requiredConfigurationEpoch = requiredConfigurationEpoch;
        emit OperationCreated(
            operationId,
            expectedStatementRoot,
            requiredConfigurationRoot,
            requiredConfigurationEpoch
        );
    }

    /// @notice Apply a pending operation using an admitted receipt.
    /// @dev Admission facts are frozen at admission time. Consumer acceptance is
    ///      determined independently by this operation's immutable acceptance policy.
    function applyOperation(bytes32 operationId, bytes32 admissionReceiptId) external {
        Operation storage op = _operations[operationId];
        if (!op.exists) revert UnknownOperation(operationId);
        if (op.applied) revert OperationAlreadyApplied(operationId);

        IPrfStatementAdmission.AdmissionReceipt memory receipt =
            admission.admissionReceipt(admissionReceiptId);
        if (!receipt.exists) revert UnknownAdmissionReceipt(admissionReceiptId);
        if (receipt.statementRoot != op.expectedStatementRoot) {
            revert StatementRootMismatch(op.expectedStatementRoot, receipt.statementRoot);
        }
        if (receipt.configurationRoot != op.requiredConfigurationRoot) {
            revert ConfigurationRootMismatch(
                op.requiredConfigurationRoot,
                receipt.configurationRoot
            );
        }
        if (receipt.configurationEpoch != op.requiredConfigurationEpoch) {
            revert ConfigurationEpochMismatch(
                op.requiredConfigurationEpoch,
                receipt.configurationEpoch
            );
        }

        bytes32 consumptionId = _consumptionId(
            operationId,
            admissionReceiptId,
            op.expectedStatementRoot,
            op.requiredConfigurationRoot,
            op.requiredConfigurationEpoch
        );
        if (consumptionUsed[consumptionId]) revert ConsumptionAlreadyUsed(consumptionId);

        // Effects are recorded before the terminal state/event. There are no external calls.
        consumptionUsed[consumptionId] = true;
        op.applied = true;
        op.admissionReceiptId = admissionReceiptId;
        op.consumptionId = consumptionId;

        emit OperationApplied(
            operationId,
            admissionReceiptId,
            consumptionId,
            op.expectedStatementRoot
        );
    }

    function operation(bytes32 operationId) external view returns (Operation memory) {
        return _operations[operationId];
    }

    function consumptionIdFor(
        bytes32 operationId,
        bytes32 admissionReceiptId,
        bytes32 statementRoot,
        bytes32 requiredConfigurationRoot,
        uint64 requiredConfigurationEpoch
    ) external view returns (bytes32) {
        return _consumptionId(
            operationId,
            admissionReceiptId,
            statementRoot,
            requiredConfigurationRoot,
            requiredConfigurationEpoch
        );
    }

    function _consumptionId(
        bytes32 operationId,
        bytes32 admissionReceiptId,
        bytes32 statementRoot,
        bytes32 requiredConfigurationRoot,
        uint64 requiredConfigurationEpoch
    ) private view returns (bytes32) {
        return keccak256(abi.encode(
            CONSUMPTION_DOMAIN,
            address(this),
            block.chainid,
            operationId,
            admissionReceiptId,
            statementRoot,
            requiredConfigurationRoot,
            requiredConfigurationEpoch
        ));
    }
}
