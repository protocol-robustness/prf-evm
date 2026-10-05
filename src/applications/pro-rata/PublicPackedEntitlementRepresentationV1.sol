// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {IEntitlementRepresentationV1} from "../../interfaces/IEntitlementRepresentationV1.sol";

/// @notice Reference implementation of the logical committed-entitlement table.
/// @dev Stores the ordered commitment sequence directly for simple conformance
///      testing. Physical sharding/storage is deliberately outside this root.
contract PublicPackedEntitlementRepresentationV1 is IEntitlementRepresentationV1 {
    bytes32 private constant NODE_DOMAIN = keccak256("prf.source-bound-entitlement.table-node.v1");
    bytes32 private constant EMPTY_DOMAIN = keccak256("prf.source-bound-entitlement.table-empty.v1");
    bytes32 private constant ROOT_DOMAIN = keccak256("prf.source-bound-entitlement.table-root.v1");

    bytes32[] private _commitments;
    bytes32 public immutable override logicalRoot;
    uint256 public immutable override entitlementCount;
    uint256 public immutable override entitlementTotal;

    error EmptyEntitlementTable();
    error ZeroEntitlementCommitment(uint256 index);

    constructor(bytes32[] memory commitments_, uint256 total_) {
        uint256 count = commitments_.length;
        if (count == 0 || total_ == 0) revert EmptyEntitlementTable();
        for (uint256 i; i < count; ++i) {
            if (commitments_[i] == bytes32(0)) revert ZeroEntitlementCommitment(i);
            _commitments.push(commitments_[i]);
        }
        entitlementCount = count;
        entitlementTotal = total_;
        logicalRoot = _summaryRoot(commitments_, count, total_);
    }

    function commitmentAt(uint256 index) external view returns (bytes32) {
        return _commitments[index];
    }

    function _summaryRoot(bytes32[] memory leaves, uint256 count, uint256 total) private pure returns (bytes32) {
        bytes32 membersRoot;
        if (leaves.length == 0) {
            membersRoot = keccak256(abi.encodePacked(EMPTY_DOMAIN));
        } else {
            while (leaves.length > 1) {
                uint256 nextLength = (leaves.length + 1) / 2;
                bytes32[] memory next = new bytes32[](nextLength);
                for (uint256 i; i < leaves.length; i += 2) {
                    bytes32 right = i + 1 < leaves.length ? leaves[i + 1] : leaves[i];
                    next[i / 2] = keccak256(abi.encodePacked(NODE_DOMAIN, leaves[i], right));
                }
                leaves = next;
            }
            membersRoot = leaves[0];
        }
        return keccak256(abi.encodePacked(ROOT_DOMAIN, membersRoot, bytes32(count), bytes32(total)));
    }
}
