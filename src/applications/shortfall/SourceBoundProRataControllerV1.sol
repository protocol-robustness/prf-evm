// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {IPrfStatementAdmission} from "../../interfaces/IPrfStatementAdmission.sol";
import {PrfSourceBoundStatementVerifierAdapter} from "../../verification/adapters/PrfSourceBoundStatementVerifierAdapter.sol";
import {PrfRealizedExecutionVerifierAdapter} from "../../verification/adapters/PrfRealizedExecutionVerifierAdapter.sol";
import {OnchainShortfallReserveV1} from "./OnchainShortfallReserveV1.sol";
import {ProductionProRataAllocatorV1} from "../pro-rata/ProductionProRataAllocatorV1.sol";

/// @notice Non-custodial application reliance consumer for source-bound Shortfall proofs.
/// @dev The controller is the reserve applicationAuthority. It owns no funds and
///      performs no allocation arithmetic.
contract SourceBoundProRataControllerV1 {
    enum State { None, ReserveLocked, SourceAssured, AllocatorConfigured, ExecutionActivated, Cancelled, Expired }

    IPrfStatementAdmission public immutable admission;
    OnchainShortfallReserveV1 public immutable reserve;
    ProductionProRataAllocatorV1 public immutable allocator;
    PrfSourceBoundStatementVerifierAdapter public immutable sourceAdapter;
    PrfRealizedExecutionVerifierAdapter public immutable executionAdapter;
    address public immutable operationInitiator;
    address public immutable residualRecipient;
    bytes32 public immutable expectedProtocolGenesisRoot;
    bytes32 public immutable expectedChainInstanceGenesisRoot;
    bytes32 public immutable expectedConfigurationRoot;
    uint64 public immutable expectedConfigurationEpoch;
    bytes32 public immutable expectedSourceVerifierRegistryRoot;
    bytes32 public immutable expectedSourceVerifierId;
    bytes32 public immutable expectedExecutionVerifierId;
    bytes32 public immutable expectedSourceProgramVKey;
    bytes32 public immutable expectedSourceProgramElfSha256;
    bytes32 public immutable expectedSourceStatementSchema;
    bytes32 public immutable expectedSourcePublicValuesSchema;

    struct Assurance {
        bool exists;
        bytes32 allocationBindingRoot;
        bytes32 realizedStatementRoot;
        bytes32 operationId;
        bytes32 reserveSnapshotHash;
        bytes32 receiptId;
        bytes32 publicValuesDigest;
    }
    mapping(bytes32 => State) public state;
    mapping(bytes32 => Assurance) public assurance;

    error OnlyOperationInitiator(address caller);
    error InvalidState(State actual);
    error InvalidReceipt();
    error IdentityMismatch();
    error PublicValuesMismatch();
    error SourceOperationMismatch();
    error SnapshotMismatch();
    error ExecutionMismatch();
    error ReserveMismatch();

    constructor(
        IPrfStatementAdmission admission_,
        OnchainShortfallReserveV1 reserve_,
        ProductionProRataAllocatorV1 allocator_,
        PrfSourceBoundStatementVerifierAdapter sourceAdapter_,
        PrfRealizedExecutionVerifierAdapter executionAdapter_,
        address operationInitiator_,
        address residualRecipient_,
        bytes32 protocolGenesisRoot_,
        bytes32 chainInstanceGenesisRoot_,
        bytes32 configurationRoot_,
        uint64 configurationEpoch_,
        bytes32 sourceVerifierRegistryRoot_,
        bytes32 sourceVerifierId_,
        bytes32 executionVerifierId_
    ) {
        require(address(admission_) != address(0) && address(reserve_) != address(0)
            && address(allocator_) != address(0) && address(sourceAdapter_) != address(0)
            && address(executionAdapter_) != address(0) && operationInitiator_ != address(0)
            && residualRecipient_ != address(0), "SBPC: zero value");
        if (reserve_.applicationAuthority() != address(this)
            || address(reserve_.allocator()) != address(0)
            || allocator_.operationAuthority() != address(reserve_)) revert ReserveMismatch();

        admission = admission_; reserve = reserve_; allocator = allocator_;
        sourceAdapter = sourceAdapter_; executionAdapter = executionAdapter_;
        operationInitiator = operationInitiator_; residualRecipient = residualRecipient_;
        expectedProtocolGenesisRoot = protocolGenesisRoot_;
        expectedChainInstanceGenesisRoot = chainInstanceGenesisRoot_;
        expectedConfigurationRoot = configurationRoot_;
        expectedConfigurationEpoch = configurationEpoch_;
        expectedSourceVerifierRegistryRoot = sourceVerifierRegistryRoot_;
        expectedSourceVerifierId = sourceVerifierId_;
        expectedExecutionVerifierId = executionVerifierId_;
        expectedSourceProgramVKey = sourceAdapter_.programVKey();
        expectedSourceProgramElfSha256 = sourceAdapter_.programElfSha256();
        expectedSourceStatementSchema = sourceAdapter_.statementSchemaVersion();
        expectedSourcePublicValuesSchema = sourceAdapter_.publicValuesSchema();

        reserve_.bindAllocator(allocator_);
        if (address(reserve_.allocator()) != address(allocator_)) revert ReserveMismatch();
    }

    function lockOperation(bytes32 operationId) external {
        if (msg.sender != operationInitiator) revert OnlyOperationInitiator(msg.sender);
        if (operationId == bytes32(0) || state[operationId] != State.None) revert InvalidState(state[operationId]);
        reserve.lockAvailableFor(operationId);
        uint64 snapshotId = reserve.snapshotIdForOperation(operationId);
        (bytes32 snapshotOperation, address snapshotAllocator,,,,,, bytes32 snapshotHash) = reserve.availabilitySnapshots(snapshotId);
        if (snapshotId == 0 || snapshotOperation != operationId || snapshotAllocator != address(allocator) || snapshotHash == bytes32(0)) revert SnapshotMismatch();
        state[operationId] = State.ReserveLocked;
    }

    function consumeSourceAssurance(bytes32 operationId, bytes32 receiptId, bytes calldata publicValues) external {
        if (state[operationId] != State.ReserveLocked) revert InvalidState(state[operationId]);
        IPrfStatementAdmission.AdmissionReceipt memory r = admission.admissionReceipt(receiptId);
        if (!r.exists || r.protocolGenesisRoot != expectedProtocolGenesisRoot
            || r.chainInstanceGenesisRoot != expectedChainInstanceGenesisRoot
            || r.configurationRoot != expectedConfigurationRoot || r.configurationEpoch != expectedConfigurationEpoch
            || r.verifierRegistryRoot != expectedSourceVerifierRegistryRoot || r.verifierId != expectedSourceVerifierId
            || r.verifierAdapter != address(sourceAdapter) || r.programVKey != expectedSourceProgramVKey
            || r.programElfSha256 != expectedSourceProgramElfSha256 || r.statementSchemaVersionHash != expectedSourceStatementSchema
            || r.publicValuesSchema != expectedSourcePublicValuesSchema) revert IdentityMismatch();
        if (r.publicValuesDigest != sha256(publicValues)) revert PublicValuesMismatch();
        PrfSourceBoundStatementVerifierAdapter.SourceBoundPublicValues memory p = sourceAdapter.decodePublicValues(publicValues);
        if (r.statementRoot != p.allocationBindingRoot || p.operationId != operationId) revert SourceOperationMismatch();
        uint64 snapshotId = reserve.snapshotIdForOperation(operationId);
        (bytes32 snapshotOperation, address snapshotAllocator,,,,,, bytes32 snapshotHash) = reserve.availabilitySnapshots(snapshotId);
        if (snapshotId == 0 || snapshotOperation != operationId || snapshotAllocator != address(allocator) || snapshotHash != p.reserveSnapshotHash) revert SnapshotMismatch();
        assurance[operationId] = Assurance(true, p.allocationBindingRoot, p.realizedStatementRoot, p.operationId, p.reserveSnapshotHash, receiptId, r.publicValuesDigest);
        state[operationId] = State.SourceAssured;
    }

    function createReserveOperation(bytes32 operationId) external {
        if (state[operationId] != State.SourceAssured) revert InvalidState(state[operationId]);
        Assurance memory a = assurance[operationId];
        reserve.createAllocatorOperation(operationId, a.realizedStatementRoot, expectedConfigurationRoot, expectedConfigurationEpoch, residualRecipient);
        state[operationId] = State.AllocatorConfigured;
    }

    function fundOperation(bytes32 operationId) external {
        if (state[operationId] != State.AllocatorConfigured) revert InvalidState(state[operationId]);
        reserve.fundOperation(operationId);
    }

    function cancelOperation(bytes32 operationId) external {
            if (msg.sender != operationInitiator) revert OnlyOperationInitiator(msg.sender);
            State current = state[operationId];
            if (current != State.ReserveLocked && current != State.SourceAssured && current != State.AllocatorConfigured) revert InvalidState(current);
            reserve.cancelShortfallOperation(operationId);
            state[operationId] = State.Cancelled;
        }

        function expireOperation(bytes32 operationId) external {
            State current = state[operationId];
            if (current != State.ReserveLocked && current != State.SourceAssured && current != State.AllocatorConfigured) revert InvalidState(current);
            reserve.expireShortfallOperation(operationId);
            state[operationId] = State.Expired;
        }

        function activate(bytes32 operationId, bytes32 receiptId, bytes calldata publicValues) external {
        if (state[operationId] != State.AllocatorConfigured) revert InvalidState(state[operationId]);
        Assurance memory a = assurance[operationId];
        IPrfStatementAdmission.AdmissionReceipt memory r = admission.admissionReceipt(receiptId);
        if (!r.exists || r.verifierId != expectedExecutionVerifierId || r.verifierAdapter != address(executionAdapter)
            || r.configurationRoot != expectedConfigurationRoot || r.configurationEpoch != expectedConfigurationEpoch
            || r.programVKey != executionAdapter.programVKey() || r.programElfSha256 != executionAdapter.programElfSha256()
            || r.statementSchemaVersionHash != executionAdapter.statementSchemaVersion()
            || r.publicValuesSchema != executionAdapter.publicValuesSchema()
            || r.publicValuesDigest != sha256(publicValues)) revert IdentityMismatch();
        PrfRealizedExecutionVerifierAdapter.ExecutionPublicValues memory p = executionAdapter.decodePublicValues(publicValues);
        if (p.operationId != a.operationId || p.statementRoot != a.realizedStatementRoot) revert ExecutionMismatch();
        reserve.activateAllocatorOperation(operationId, receiptId, publicValues);
        state[operationId] = State.ExecutionActivated;
    }
}
