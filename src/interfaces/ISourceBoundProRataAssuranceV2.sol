// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

interface ISourceBoundProRataAssuranceV2 {
    struct RatificationPayload {
        bytes32 preparedOperationRoot;
        bytes32 reserveStateCommitment;
        bytes32 allocationBindingRoot;
        bytes32 realizedStatementRoot;
        bytes32 operationId;
        bytes32 receiptId;
    }

    /// @notice One-shot application-level consumption for the exact ratification tuple.
    /// @dev Reversion by the caller must revert this consumption.
    function consumeForRatification(bytes32 operationId, bytes32 preparedOperationRoot, bytes32 reserveStateCommitment)
        external
        returns (RatificationPayload memory);

    /// @notice Replaces a stale, unconsumed assurance after fresh admission checks.
    /// @dev Callable only by the permanently bound ratification controller.
    function replaceStaleAssurance(
        bytes32 operationId,
        bytes32 expectedOldAssuranceCommitment,
        bytes32 expectedReplacementAssuranceCommitment,
        uint64 expectedGeneration,
        bytes32 replacementReceiptId,
        bytes calldata replacementPublicValues,
        bytes32 liveReserveCommitment
    ) external returns (bytes32 oldCommitment, bytes32 newCommitment, uint64 oldGeneration, uint64 newGeneration);

    function assuranceCommitment(bytes32 operationId) external view returns (bytes32);
    function assuranceCommitmentFor(bytes32 operationId, bytes32 receiptId, bytes32 publicValuesHash, uint64 generation)
        external
        pure
        returns (bytes32);
}
