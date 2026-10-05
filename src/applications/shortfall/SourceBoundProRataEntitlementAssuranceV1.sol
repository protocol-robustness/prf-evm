// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {IPrfStatementAdmission} from "../../interfaces/IPrfStatementAdmission.sol";
import {
    PrfSourceBoundEntitlementVerifierAdapterV1
} from "../../verification/adapters/PrfSourceBoundEntitlementVerifierAdapterV1.sol";
import {SourceBoundProRataControllerV2} from "./SourceBoundProRataControllerV2.sol";

/// @notice Assurance lifecycle for the source-bound entitlement V1 proof profile.
/// @dev Additive successor to SourceBoundProRataAssuranceV2. It validates and
///      freezes the nine-word entitlement proof tuple; it does not move capital.
contract SourceBoundProRataEntitlementAssuranceV1 {
    enum State {
        None,
        Prepared,
        Consumed
    }

    struct PreparedEntitlementAssurance {
        bytes32 operationId;
        bytes32 receiptId;
        bytes32 publicValuesHash;
        bytes32 preparedOperationRoot;
        bytes32 reserveStateCommitment;
        bytes32 allocationBindingRoot;
        bytes32 descriptorRoot;
        bytes32 evmEntitlementTableRoot;
        uint256 entitlementCount;
        uint256 entitlementTotal;
        bytes32 allocationClaimRoot;
        bytes32 verifierIdentity;
        bytes32 programVKey;
        bytes32 programElfSha256;
        bytes32 statementSchema;
        bytes32 publicValuesSchema;
        State state;
    }

    struct RatificationPayload {
        bytes32 operationId;
        bytes32 receiptId;
        bytes32 preparedOperationRoot;
        bytes32 reserveStateCommitment;
        bytes32 allocationBindingRoot;
        bytes32 descriptorRoot;
        bytes32 evmEntitlementTableRoot;
        uint256 entitlementCount;
        uint256 entitlementTotal;
        bytes32 allocationClaimRoot;
    }

    IPrfStatementAdmission public immutable admission;
    PrfSourceBoundEntitlementVerifierAdapterV1 public immutable sourceAdapter;
    SourceBoundProRataControllerV2 public immutable preparedController;
    address public immutable governance;
    address public ratificationController;
    bool public controllerBindingFinalized;

    mapping(bytes32 => bool) public consumedAssurance;
    mapping(bytes32 => bytes32) public assuranceForOperation;
    mapping(bytes32 => bytes32) public operationForReceipt;
    mapping(bytes32 => PreparedEntitlementAssurance) private _prepared;

    error OnlyGovernance(address caller);
    error ControllerAlreadyBound();
    error ControllerNotBound();
    error OnlyRatificationController(address caller);
    error InvalidController();
    error InvalidPreparedOperation();
    error AssuranceAlreadyPrepared(bytes32 operationId);
    error ReceiptAlreadyPrepared(bytes32 receiptId);
    error InvalidReceipt();
    error InvalidIdentity();
    error InvalidPublicValues();
    error OperationMismatch();
    error StatementMismatch();
    error AssuranceAlreadyConsumed(bytes32 receiptId);

    event RatificationControllerBound(address indexed controller);
    event EntitlementAssurancePrepared(
        bytes32 indexed operationId,
        bytes32 indexed receiptId,
        bytes32 indexed evmEntitlementTableRoot,
        uint256 entitlementCount,
        uint256 entitlementTotal
    );
    event EntitlementAssuranceConsumed(bytes32 indexed operationId, bytes32 indexed receiptId);

    constructor(
        IPrfStatementAdmission admission_,
        PrfSourceBoundEntitlementVerifierAdapterV1 sourceAdapter_,
        SourceBoundProRataControllerV2 preparedController_,
        address governance_
    ) {
        require(
            address(admission_) != address(0) && address(sourceAdapter_) != address(0)
                && address(preparedController_) != address(0) && governance_ != address(0),
            "SBEA1: zero value"
        );
        admission = admission_;
        sourceAdapter = sourceAdapter_;
        preparedController = preparedController_;
        governance = governance_;
    }

    /// @notice Permanently binds the only controller allowed to consume assurance.
    function bindRatificationController(address controller_) external {
        if (msg.sender != governance) revert OnlyGovernance(msg.sender);
        if (controllerBindingFinalized) revert ControllerAlreadyBound();
        if (controller_ == address(0)) revert InvalidController();
        ratificationController = controller_;
        controllerBindingFinalized = true;
        emit RatificationControllerBound(controller_);
    }

    /// @notice Validates an admitted successor proof and freezes its derived tuple.
    function prepareSourceAssurance(bytes32 operationId, bytes32 receiptId, bytes calldata publicValues)
        external
        returns (PreparedEntitlementAssurance memory prepared)
    {
        if (!controllerBindingFinalized) revert ControllerNotBound();
        if (
            preparedController.state(operationId) != SourceBoundProRataControllerV2.State.Prepared
                || !preparedController.successorEntitlementProfile(operationId)
        ) revert InvalidPreparedOperation();
        if (_prepared[operationId].state != State.None) revert AssuranceAlreadyPrepared(operationId);
        if (operationForReceipt[receiptId] != bytes32(0)) revert ReceiptAlreadyPrepared(receiptId);

        IPrfStatementAdmission.AdmissionReceipt memory receipt = admission.admissionReceipt(receiptId);
        if (!receipt.exists || receipt.verifierAdapter != address(sourceAdapter)) revert InvalidReceipt();
        if (
            receipt.programVKey != sourceAdapter.programVKey()
                || receipt.programElfSha256 != sourceAdapter.programElfSha256()
                || receipt.statementSchemaVersionHash != sourceAdapter.statementSchemaVersion()
                || receipt.publicValuesSchema != sourceAdapter.publicValuesSchema()
                || receipt.publicValuesDigest != sha256(publicValues)
        ) revert InvalidIdentity();
        if (
            receipt.configurationRoot != preparedController.preparedConfigurationRoot(operationId)
                || receipt.configurationEpoch != preparedController.preparedConfigurationEpoch(operationId)
                || receipt.verifierId != preparedController.preparedSourceVerifierId(operationId)
                || receipt.programVKey != preparedController.preparedSourceProgramVKey(operationId)
                || receipt.programElfSha256 != preparedController.preparedSourceProgramElfSha256(operationId)
                || receipt.statementSchemaVersionHash != preparedController.preparedSourceStatementSchema(operationId)
                || receipt.publicValuesSchema != preparedController.preparedSourcePublicValuesSchema(operationId)
        ) revert InvalidIdentity();

        PrfSourceBoundEntitlementVerifierAdapterV1.SourceBoundEntitlementPublicValuesV1 memory values =
            sourceAdapter.decodePublicValues(publicValues);
        if (values.preparedOperationRoot != preparedController.preparedOperationRoot(operationId)) {
            revert InvalidPublicValues();
        }
        if (receipt.statementRoot != values.allocationBindingRoot) revert StatementMismatch();
        if (
            values.entitlementCount == 0 || values.entitlementTotal == 0 || values.evmEntitlementTableRoot == bytes32(0)
                || values.allocationClaimRoot == bytes32(0)
        ) revert InvalidPublicValues();

        prepared = PreparedEntitlementAssurance({
            operationId: operationId,
            receiptId: receiptId,
            publicValuesHash: keccak256(publicValues),
            preparedOperationRoot: values.preparedOperationRoot,
            reserveStateCommitment: values.reserveStateCommitment,
            allocationBindingRoot: values.allocationBindingRoot,
            descriptorRoot: values.entitlementRepresentationDescriptorRoot,
            evmEntitlementTableRoot: values.evmEntitlementTableRoot,
            entitlementCount: values.entitlementCount,
            entitlementTotal: values.entitlementTotal,
            allocationClaimRoot: values.allocationClaimRoot,
            verifierIdentity: receipt.verifierId,
            programVKey: receipt.programVKey,
            programElfSha256: receipt.programElfSha256,
            statementSchema: receipt.statementSchemaVersionHash,
            publicValuesSchema: receipt.publicValuesSchema,
            state: State.Prepared
        });
        _prepared[operationId] = prepared;
        operationForReceipt[receiptId] = operationId;
        emit EntitlementAssurancePrepared(
            operationId, receiptId, values.evmEntitlementTableRoot, values.entitlementCount, values.entitlementTotal
        );
    }

    function preparedAssurance(bytes32 operationId) external view returns (PreparedEntitlementAssurance memory) {
        return _prepared[operationId];
    }

    /// @notice One-shot handoff of the exact prepared proof tuple to ratification.
    function consumeForRatification(bytes32 operationId, bytes32 preparedRoot, bytes32 reserveCommitment)
        external
        returns (RatificationPayload memory result)
    {
        if (!controllerBindingFinalized) revert ControllerNotBound();
        if (msg.sender != ratificationController) revert OnlyRatificationController(msg.sender);
        PreparedEntitlementAssurance storage prepared = _prepared[operationId];
        if (prepared.state != State.Prepared) revert InvalidPreparedOperation();
        if (prepared.preparedOperationRoot != preparedRoot || prepared.reserveStateCommitment != reserveCommitment) {
            revert InvalidPublicValues();
        }
        if (consumedAssurance[prepared.receiptId]) revert AssuranceAlreadyConsumed(prepared.receiptId);

        prepared.state = State.Consumed;
        consumedAssurance[prepared.receiptId] = true;
        assuranceForOperation[operationId] = prepared.receiptId;
        result = RatificationPayload(
            prepared.operationId,
            prepared.receiptId,
            prepared.preparedOperationRoot,
            prepared.reserveStateCommitment,
            prepared.allocationBindingRoot,
            prepared.descriptorRoot,
            prepared.evmEntitlementTableRoot,
            prepared.entitlementCount,
            prepared.entitlementTotal,
            prepared.allocationClaimRoot
        );
        emit EntitlementAssuranceConsumed(operationId, prepared.receiptId);
    }
}
