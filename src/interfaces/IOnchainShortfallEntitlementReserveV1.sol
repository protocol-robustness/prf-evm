// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {IEntitlementRepresentationV1} from "./IEntitlementRepresentationV1.sol";

/// @notice Additive exact-funding route for the successor entitlement proof profile.
interface IOnchainShortfallEntitlementReserveV1 {
    struct EntitlementRatificationRequest {
        bytes32 operationId;
        bytes32 preparedOperationRoot;
        bytes32 expectedReserveStateCommitment;
        bytes32 allocationBindingRoot;
        bytes32 descriptorRoot;
        bytes32 evmEntitlementTableRoot;
        uint256 entitlementCount;
        uint256 entitlementTotal;
        bytes32 allocationClaimRoot;
        address residualRecipient;
    }

    struct EntitlementRatificationResult {
        bytes32 authoritativeObservationRoot;
        uint64 snapshotId;
        uint256 fundedAmount;
        uint64 successorAvailabilityRevision;
    }

    function ratifyAndFundEntitlement(EntitlementRatificationRequest calldata request)
        external
        returns (EntitlementRatificationResult memory);

    function activateEntitlement(bytes32 operationId, IEntitlementRepresentationV1 representation) external;
}
