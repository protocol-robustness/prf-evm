// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {IPrfStatementAdmission} from "../../interfaces/IPrfStatementAdmission.sol";
import {PrfSourceBoundStatementVerifierAdapterV2} from "../../verification/adapters/PrfSourceBoundStatementVerifierAdapterV2.sol";
import {ISourceBoundProRataAssuranceV2} from "../../interfaces/ISourceBoundProRataAssuranceV2.sol";
import {SourceBoundProRataControllerV2} from "./SourceBoundProRataControllerV2.sol";

/// @notice V2 source-assurance lifecycle. Preparation validates an admitted
/// proof without consuming it; consumption is controller-only and atomic with
/// the subsequent reserve ratification.
contract SourceBoundProRataAssuranceV2 is ISourceBoundProRataAssuranceV2 {
    enum AssuranceState { None, Prepared, Consumed }

    struct PreparedSourceAssurance {
        bytes32 operationId;
        bytes32 receiptId;
        bytes32 publicValuesHash;
        bytes32 preparedOperationRoot;
        bytes32 reserveStateCommitment;
        bytes32 allocationBindingRoot;
        bytes32 realizedStatementRoot;
        bytes32 verifierIdentity;
        bytes32 programVKey;
        bytes32 programElfSha256;
        bytes32 statementSchema;
        bytes32 publicValuesSchema;
        AssuranceState state;
    }

    IPrfStatementAdmission public immutable admission;
    PrfSourceBoundStatementVerifierAdapterV2 public immutable sourceAdapter;
    SourceBoundProRataControllerV2 public immutable preparedController;
    address public immutable governance;
    address public ratificationController;
    bool public controllerBindingFinalized;

    mapping(bytes32 => bool) public consumedAssurance;
    mapping(bytes32 => bytes32) public assuranceForOperation;
    mapping(bytes32 => PreparedSourceAssurance) private _preparedAssurance;
    mapping(bytes32 => bytes32) public operationForReceipt;

    error InvalidPreparedOperation();
    error InvalidReceipt();
    error InvalidIdentity();
    error InvalidPublicValues();
    error AssuranceAlreadyConsumed(bytes32 receiptId);
    error AssuranceAlreadyPrepared(bytes32 operationId);
    error ReceiptAlreadyPrepared(bytes32 receiptId);
    error OperationMismatch();
    error StatementMismatch();
    error OnlyGovernance(address caller);
    error ControllerAlreadyBound();
    error ControllerNotBound();
    error OnlyRatificationController(address caller);
    error InvalidController();

    event RatificationControllerBound(address indexed controller);
    event SourceAssurancePrepared(bytes32 indexed operationId, bytes32 indexed receiptId, bytes32 reserveStateCommitment);
    event SourceAssuranceConsumed(bytes32 indexed operationId, bytes32 indexed receiptId, bytes32 reserveStateCommitment);

    constructor(
        IPrfStatementAdmission admission_,
        PrfSourceBoundStatementVerifierAdapterV2 sourceAdapter_,
        SourceBoundProRataControllerV2 preparedController_,
        address governance_
    ) {
        require(
            address(admission_) != address(0) && address(sourceAdapter_) != address(0)
                && address(preparedController_) != address(0) && governance_ != address(0),
            "SBA2: zero value"
        );
        admission = admission_;
        sourceAdapter = sourceAdapter_;
        preparedController = preparedController_;
        governance = governance_;
    }

    /// @notice Permanently binds the orchestration controller before use.
    function bindRatificationController(address controller_) external {
        if (msg.sender != governance) revert OnlyGovernance(msg.sender);
        if (controllerBindingFinalized) revert ControllerAlreadyBound();
        if (controller_ == address(0)) revert InvalidController();
        ratificationController = controller_;
        controllerBindingFinalized = true;
        emit RatificationControllerBound(controller_);
    }

    /// @notice Validates and freezes an admitted V2 assurance without capital effect.
    function prepareSourceAssurance(bytes32 operationId, bytes32 receiptId, bytes calldata publicValues)
        external returns (PreparedSourceAssurance memory prepared)
    {
        if (!controllerBindingFinalized) revert ControllerNotBound();
        if (preparedController.state(operationId) != SourceBoundProRataControllerV2.State.Prepared) {
            revert InvalidPreparedOperation();
        }
        if (_preparedAssurance[operationId].state != AssuranceState.None) revert AssuranceAlreadyPrepared(operationId);
        if (operationForReceipt[receiptId] != bytes32(0)) revert ReceiptAlreadyPrepared(receiptId);

        IPrfStatementAdmission.AdmissionReceipt memory receipt = admission.admissionReceipt(receiptId);
        if (!receipt.exists || receipt.verifierAdapter != address(sourceAdapter)) revert InvalidReceipt();
        if (receipt.programVKey != sourceAdapter.programVKey()
            || receipt.programElfSha256 != sourceAdapter.programElfSha256()
            || receipt.statementSchemaVersionHash != sourceAdapter.statementSchemaVersion()
            || receipt.publicValuesSchema != sourceAdapter.publicValuesSchema()
            || receipt.publicValuesDigest != sha256(publicValues)) revert InvalidIdentity();

        PrfSourceBoundStatementVerifierAdapterV2.SourceBoundPublicValuesV2 memory values =
            sourceAdapter.decodePublicValues(publicValues);
        if (values.operationId != operationId) revert OperationMismatch();
        if (receipt.statementRoot != values.allocationBindingRoot) revert StatementMismatch();
        bytes32 preparedRoot = preparedController.preparedOperationRoot(operationId);
        if (values.preparedOperationRoot != preparedRoot) revert InvalidPublicValues();

        prepared = PreparedSourceAssurance({
            operationId: operationId,
            receiptId: receiptId,
            publicValuesHash: keccak256(publicValues),
            preparedOperationRoot: values.preparedOperationRoot,
            reserveStateCommitment: values.reserveStateCommitment,
            allocationBindingRoot: values.allocationBindingRoot,
            realizedStatementRoot: values.realizedStatementRoot,
            verifierIdentity: receipt.verifierId,
            programVKey: receipt.programVKey,
            programElfSha256: receipt.programElfSha256,
            statementSchema: receipt.statementSchemaVersionHash,
            publicValuesSchema: receipt.publicValuesSchema,
            state: AssuranceState.Prepared
        });
        _preparedAssurance[operationId] = prepared;
        operationForReceipt[receiptId] = operationId;
        emit SourceAssurancePrepared(operationId, receiptId, values.reserveStateCommitment);
    }

    function preparedAssurance(bytes32 operationId) external view returns (PreparedSourceAssurance memory) {
        return _preparedAssurance[operationId];
    }

    /// @notice Consumes only the exact prepared tuple for the bound controller.
    function consumeForRatification(bytes32 operationId, bytes32 preparedRoot, bytes32 commitment)
        external override returns (RatificationPayload memory result)
    {
        if (!controllerBindingFinalized) revert ControllerNotBound();
        if (msg.sender != ratificationController) revert OnlyRatificationController(msg.sender);
        PreparedSourceAssurance storage prepared = _preparedAssurance[operationId];
        if (prepared.state != AssuranceState.Prepared) revert InvalidPreparedOperation();
        if (prepared.preparedOperationRoot != preparedRoot) revert InvalidPublicValues();
        if (prepared.reserveStateCommitment != commitment) revert InvalidPublicValues();
        if (consumedAssurance[prepared.receiptId]) revert AssuranceAlreadyConsumed(prepared.receiptId);

        prepared.state = AssuranceState.Consumed;
        consumedAssurance[prepared.receiptId] = true;
        assuranceForOperation[operationId] = prepared.receiptId;
        result = RatificationPayload(
            prepared.preparedOperationRoot,
            prepared.reserveStateCommitment,
            prepared.allocationBindingRoot,
            prepared.realizedStatementRoot,
            prepared.operationId,
            prepared.receiptId
        );
        emit SourceAssuranceConsumed(operationId, prepared.receiptId, prepared.reserveStateCommitment);
    }

    /// @dev Retained as an explicit migration guard; V2 preparation and
    /// consumption must not be split into an externally consumable operation.
    function consumeSourceAssurance(bytes32, bytes32, bytes calldata) external pure {
        revert InvalidIdentity();
    }
}
