// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IShortfallAllocatorV2} from "./IShortfallAllocatorV2.sol";

interface IOnchainShortfallReserveV2 {
    function token() external view returns (IERC20);
    function allocator() external view returns (IShortfallAllocatorV2);

    struct RatificationRequest {
        bytes32 operationId;
        bytes32 preparedOperationRoot;
        bytes32 expectedReserveStateCommitment;
        bytes32 allocationBindingRoot;
        bytes32 realizedStatementRoot;
        bytes32 configurationRoot;
        uint64 configurationEpoch;
        address residualRecipient;
    }

    struct RatificationResult {
        bytes32 authoritativeObservationRoot;
        uint64 snapshotId;
        uint256 fundedAmount;
        uint64 successorAvailabilityRevision;
    }

    /// @notice Atomically compares live economic state, records the authoritative
    /// observation, creates/funds the allocator operation, and leaves no reservation.
    function ratifyAndFund(RatificationRequest calldata request) external returns (RatificationResult memory);
}
