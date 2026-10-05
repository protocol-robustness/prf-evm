// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IShortfallAllocatorV2} from "./IShortfallAllocatorV2.sol";
import {IEntitlementRepresentationV1} from "./IEntitlementRepresentationV1.sol";

/// @notice Successor funding record for the nine-word entitlement proof profile.
/// @dev Kept separate from IShortfallAllocatorV2 because that frozen ABI requires
///      a realizedStatementRoot which this proof profile intentionally omits.
interface IShortfallEntitlementAllocatorV1 {
    struct EntitlementOperation {
        IShortfallAllocatorV2.State state;
        bytes32 allocationBindingRoot;
        bytes32 descriptorRoot;
        bytes32 evmEntitlementTableRoot;
        uint256 entitlementCount;
        uint256 entitlementTotal;
        bytes32 allocationClaimRoot;
        IERC20 token;
        uint256 amount;
        address residualRecipient;
        address representation;
    }

    function createEntitlement(
        bytes32 operationId,
        bytes32 allocationBindingRoot,
        bytes32 descriptorRoot,
        bytes32 evmEntitlementTableRoot,
        uint256 entitlementCount,
        uint256 entitlementTotal,
        bytes32 allocationClaimRoot,
        IERC20 token,
        uint256 amount,
        address residualRecipient
    ) external;

    function fundEntitlement(bytes32 operationId) external;
    function activateEntitlement(bytes32 operationId, IEntitlementRepresentationV1 representation) external;
    function entitlementOperation(bytes32 operationId) external view returns (EntitlementOperation memory);
}
