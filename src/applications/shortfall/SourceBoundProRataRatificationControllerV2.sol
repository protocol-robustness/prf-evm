// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {ISourceBoundProRataAssuranceV2} from "../../interfaces/ISourceBoundProRataAssuranceV2.sol";
import {IOnchainShortfallReserveV2} from "../../interfaces/IOnchainShortfallReserveV2.sol";
import {SourceBoundProRataControllerV2} from "./SourceBoundProRataControllerV2.sol";

/// @notice V2 orchestration shell for atomic ratification.
/// @dev This contract is intentionally not deployable as a complete capital
/// path until a concrete ReserveV2 implements IOnchainShortfallReserveV2.
contract SourceBoundProRataRatificationControllerV2 {
    enum State { None, Prepared, Ratifying, Funded }

    SourceBoundProRataControllerV2 public immutable preparedController;
    ISourceBoundProRataAssuranceV2 public immutable assurance;
    IOnchainShortfallReserveV2 public immutable reserve;

    mapping(bytes32 => State) public state;
    mapping(bytes32 => IOnchainShortfallReserveV2.RatificationResult) public result;

    error InvalidState(State actual);
    error PreparedRootMismatch();
    error OperationMismatch();
    error AllocationMismatch();

    event RatificationStarted(bytes32 indexed operationId, bytes32 indexed commitment);
    event RatificationFunded(bytes32 indexed operationId, uint256 amount, uint64 revision);

    constructor(
        SourceBoundProRataControllerV2 preparedController_,
        ISourceBoundProRataAssuranceV2 assurance_,
        IOnchainShortfallReserveV2 reserve_
    ) {
        require(address(preparedController_) != address(0) && address(assurance_) != address(0) && address(reserve_) != address(0), "SBRC2: zero value");
        preparedController = preparedController_;
        assurance = assurance_;
        reserve = reserve_;
    }

    function registerPrepared(bytes32 operationId) external {
        if (preparedController.state(operationId) != SourceBoundProRataControllerV2.State.Prepared) revert InvalidState(state[operationId]);
        if (state[operationId] != State.None) revert InvalidState(state[operationId]);
        state[operationId] = State.Prepared;
    }

    function ratifyAndFund(
        bytes32 operationId,
        bytes32 expectedReserveStateCommitment,
        bytes32 configurationRoot,
        uint64 configurationEpoch,
        address residualRecipient
    ) external {
        if (state[operationId] != State.Prepared) revert InvalidState(state[operationId]);
        state[operationId] = State.Ratifying;
        bytes32 preparedRoot = preparedController.preparedOperationRoot(operationId);
        ISourceBoundProRataAssuranceV2.RatificationPayload memory payload =
            assurance.consumeForRatification(operationId, preparedRoot, expectedReserveStateCommitment);
        if (payload.operationId != operationId) revert OperationMismatch();
        if (payload.preparedOperationRoot != preparedRoot) revert PreparedRootMismatch();
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
}
