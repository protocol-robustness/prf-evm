// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

/// @notice Logical entitlement table identity, independent of physical storage.
interface IEntitlementRepresentationV1 {
    function logicalRoot() external view returns (bytes32);
    function entitlementCount() external view returns (uint256);
    function entitlementTotal() external view returns (uint256);
}
