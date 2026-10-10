// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {ISourceBoundProRataAssuranceV2} from "../../interfaces/ISourceBoundProRataAssuranceV2.sol";
import {IOnchainShortfallReserveV2} from "../../interfaces/IOnchainShortfallReserveV2.sol";
import {SourceBoundProRataControllerV2} from "./SourceBoundProRataControllerV2.sol";

/// @notice V2 orchestration shell for atomic ratification.
/// @dev This contract is intentionally not deployable as a complete capital
/// path until a concrete ReserveV2 implements IOnchainShortfallReserveV2.
contract SourceBoundProRataRatificationControllerV2 {
    enum State {
        None,
        Prepared,
        Ratifying,
        Funded,
        CancelledRefunded
    }

    SourceBoundProRataControllerV2 public immutable preparedController;
    ISourceBoundProRataAssuranceV2 public immutable assurance;
    IOnchainShortfallReserveV2 public immutable reserve;

    /// @notice The only route allowed to invoke ratification after one-time binding.
    address public executionCaller;
    bool public executionCallerBound;

    mapping(bytes32 => State) public state;
    mapping(bytes32 => IOnchainShortfallReserveV2.RatificationResult) public result;

    error InvalidState(State actual);
    error PreparedRootMismatch();
    error OperationMismatch();
    error AllocationMismatch();
    error InvalidPreparedOperation(SourceBoundProRataControllerV2.State actual);
    error PreparedContextMismatch();
    error OnlyGovernance(address caller);
    error OnlyExecutionCaller(address caller);
    error InvalidExecutionCaller();
    error ExecutionCallerAlreadyBound();

    event ExecutionCallerBound(address indexed caller);
    event RatificationStarted(bytes32 indexed operationId, bytes32 indexed commitment);
    event RatificationFunded(bytes32 indexed operationId, uint256 amount, uint64 revision);
    event OperationCancelledAndRefunded(bytes32 indexed operationId);
    event StaleSourceAssuranceReplaced(
        bytes32 indexed operationId,
        bytes32 indexed oldAssuranceCommitment,
        bytes32 indexed newAssuranceCommitment,
        uint64 oldGeneration,
        uint64 newGeneration,
        address authorizingPrincipal
    );

    constructor(
        SourceBoundProRataControllerV2 preparedController_,
        ISourceBoundProRataAssuranceV2 assurance_,
        IOnchainShortfallReserveV2 reserve_
    ) {
        require(
            address(preparedController_) != address(0) && address(assurance_) != address(0)
                && address(reserve_) != address(0),
            "SBRC2: zero value"
        );
        preparedController = preparedController_;
        assurance = assurance_;
        reserve = reserve_;
    }

    /// @notice Permanently binds this instance to its dispatcher/application route.
    /// @dev Governance is the existing authority on the prepared-operation controller.
    function bindExecutionCaller(address caller_) external {
        if (msg.sender != preparedController.governance()) revert OnlyGovernance(msg.sender);
        if (executionCallerBound) revert ExecutionCallerAlreadyBound();
        if (caller_ == address(0) || caller_.code.length == 0) revert InvalidExecutionCaller();
        executionCaller = caller_;
        executionCallerBound = true;
        emit ExecutionCallerBound(caller_);
    }

    function registerPrepared(bytes32 operationId) external {
        if (preparedController.state(operationId) != SourceBoundProRataControllerV2.State.Prepared) {
            revert InvalidState(state[operationId]);
        }
        if (state[operationId] != State.None) revert InvalidState(state[operationId]);
        state[operationId] = State.Prepared;
    }

    /// @notice Returns funded capital before downstream activation or reliance.
    function cancelAndRefund(bytes32 operationId) external {
        if (!executionCallerBound || msg.sender != executionCaller) {
            revert OnlyExecutionCaller(msg.sender);
        }
        if (state[operationId] != State.Funded) revert InvalidState(state[operationId]);
        reserve.cancelAndRefund(operationId);
        state[operationId] = State.CancelledRefunded;
        emit OperationCancelledAndRefunded(operationId);
    }

    function ratifyAndFund(
        bytes32 operationId,
        bytes32 expectedReserveStateCommitment,
        bytes32 configurationRoot,
        uint64 configurationEpoch,
        address residualRecipient
    ) external {
        if (!executionCallerBound || msg.sender != executionCaller) {
            revert OnlyExecutionCaller(msg.sender);
        }
        if (state[operationId] != State.Prepared) revert InvalidState(state[operationId]);
        if (preparedController.state(operationId) != SourceBoundProRataControllerV2.State.Prepared) {
            revert InvalidPreparedOperation(preparedController.state(operationId));
        }
        if (
            configurationRoot != preparedController.preparedConfigurationRoot(operationId)
                || configurationEpoch != preparedController.preparedConfigurationEpoch(operationId)
                || bytes32(uint256(uint160(residualRecipient)))
                    != preparedController.preparedResidualRecipient(operationId)
        ) revert PreparedContextMismatch();
        if (
            preparedController.preparedChainId(operationId) != block.chainid
                || preparedController.preparedReserve(operationId) != address(reserve)
                || preparedController.preparedToken(operationId) != address(reserve.token())
                || preparedController.preparedAllocator(operationId) != address(reserve.allocator())
                || preparedController.ratificationController() != address(this)
        ) revert PreparedContextMismatch();
        state[operationId] = State.Ratifying;
        bytes32 preparedRoot = preparedController.preparedOperationRoot(operationId);
        ISourceBoundProRataAssuranceV2.RatificationPayload memory payload =
            assurance.consumeForRatification(operationId, preparedRoot, expectedReserveStateCommitment);
        if (payload.operationId != operationId) revert OperationMismatch();
        if (payload.preparedOperationRoot != preparedRoot) revert PreparedRootMismatch();
        preparedController.finalizePreparedOperation(operationId, preparedRoot);
        IOnchainShortfallReserveV2.RatificationResult memory funded = reserve.ratifyAndFund(
            IOnchainShortfallReserveV2.RatificationRequest(
                operationId,
                preparedRoot,
                payload.reserveStateCommitment,
                payload.allocationBindingRoot,
                payload.realizedStatementRoot,
                configurationRoot,
                configurationEpoch,
                residualRecipient
            )
        );
        result[operationId] = funded;
        state[operationId] = State.Funded;
        emit RatificationFunded(operationId, funded.fundedAmount, funded.successorAvailabilityRevision);
    }

    /// @notice Replaces an admitted assurance only after its reserve snapshot becomes stale.
    function replaceStaleAssurance(
        bytes32 operationId,
        bytes32 expectedOldAssuranceCommitment,
        bytes32 expectedReplacementAssuranceCommitment,
        uint64 expectedGeneration,
        bytes32 replacementReceiptId,
        bytes calldata replacementPublicValues
    ) external {
        if (!executionCallerBound || msg.sender != executionCaller) {
            revert OnlyExecutionCaller(msg.sender);
        }
        if (state[operationId] != State.Prepared) revert InvalidState(state[operationId]);
        if (preparedController.state(operationId) != SourceBoundProRataControllerV2.State.Prepared) {
            revert InvalidPreparedOperation(preparedController.state(operationId));
        }
        bytes32 preparedRoot = preparedController.preparedOperationRoot(operationId);
        if (
            preparedController.preparedChainId(operationId) != block.chainid
                || preparedController.preparedReserve(operationId) != address(reserve)
                || preparedController.preparedToken(operationId) != address(reserve.token())
                || preparedController.preparedAllocator(operationId) != address(reserve.allocator())
                || preparedController.ratificationController() != address(this)
        ) revert PreparedContextMismatch();
        bytes32 liveCommitment = reserve.currentCommitment(preparedRoot);
        (bytes32 oldCommitment, bytes32 newCommitment, uint64 oldGeneration, uint64 newGeneration) = assurance.replaceStaleAssurance(
            operationId,
            expectedOldAssuranceCommitment,
            expectedReplacementAssuranceCommitment,
            expectedGeneration,
            replacementReceiptId,
            replacementPublicValues,
            liveCommitment
        );
        emit StaleSourceAssuranceReplaced(
            operationId, oldCommitment, newCommitment, oldGeneration, newGeneration, msg.sender
        );
    }
}
