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
    function consumeForRatification(
        bytes32 operationId,
        bytes32 preparedOperationRoot,
        bytes32 reserveStateCommitment
    ) external returns (RatificationPayload memory);
}
