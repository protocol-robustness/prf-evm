// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {IEntitlementRepresentationV1} from "../../interfaces/IEntitlementRepresentationV1.sol";

/// @dev Deploys immutable STOP-prefixed bytecode containing one packed shard.
///      The parent reads the payload with EXTCODECOPY; the shard has no callable
///      behavior and no writable storage.
contract EntitlementCommitmentDataShardV1 {
    constructor(bytes memory payload) {
        bytes memory runtimeCode = bytes.concat(bytes1(0), payload);
        assembly ("memory-safe") {
            return(add(runtimeCode, 0x20), mload(runtimeCode))
        }
    }
}

/// @notice Production logical entitlement table backed by immutable bytecode shards.
/// @dev The logical root is exactly the B2 ordered commitment tree and summary.
///      `shardSize` affects only physical deployment partitioning and is not
///      included in the logical root.
contract CommittedImmutableEntitlementRepresentationV1 is IEntitlementRepresentationV1 {
    bytes32 private constant NODE_DOMAIN = keccak256("prf.source-bound-entitlement.table-node.v1");
    bytes32 private constant EMPTY_DOMAIN = keccak256("prf.source-bound-entitlement.table-empty.v1");
    bytes32 private constant ROOT_DOMAIN = keccak256("prf.source-bound-entitlement.table-root.v1");

    // EIP-170 caps runtime code at 24,576 bytes. One leading STOP byte leaves
    // floor((24,576 - 1) / 32) = 767 complete commitment words per shard.
    uint16 public constant MAX_SHARD_ENTRIES = 767;

    address[] private _dataShards;
    uint16 public immutable shardSize;
    bytes32 public immutable override logicalRoot;
    uint256 public immutable override entitlementCount;
    uint256 public immutable override entitlementTotal;

    error EmptyEntitlementTable();
    error ZeroEntitlementCommitment(uint256 index);
    error InvalidShardSize(uint256 provided, uint256 maximum);
    error InvalidShardCodeSize(uint256 expected, uint256 actual);
    error EntitlementIndexOutOfBounds(uint256 index, uint256 count);

    /// @param commitments_ Ordered B2 EVM entitlement commitments.
    /// @param total_ Sum of canonical entitlement amounts.
    /// @param shardSize_ Physical commitments per immutable bytecode shard.
    ///        This may vary without changing the logical root.
    constructor(bytes32[] memory commitments_, uint256 total_, uint16 shardSize_) {
        uint256 count = commitments_.length;
        if (count == 0 || total_ == 0) revert EmptyEntitlementTable();
        if (shardSize_ == 0 || shardSize_ > MAX_SHARD_ENTRIES) {
            revert InvalidShardSize(shardSize_, MAX_SHARD_ENTRIES);
        }
        for (uint256 i; i < count; ++i) {
            if (commitments_[i] == bytes32(0)) revert ZeroEntitlementCommitment(i);
        }

        shardSize = shardSize_;
        entitlementCount = count;
        entitlementTotal = total_;
        logicalRoot = _summaryRoot(commitments_, count, total_);

        for (uint256 start; start < count; start += shardSize_) {
            uint256 remaining = count - start;
            uint256 entries = remaining < shardSize_ ? remaining : shardSize_;
            bytes memory payload = new bytes(entries * 32);
            for (uint256 i; i < entries; ++i) {
                bytes32 commitment = commitments_[start + i];
                assembly ("memory-safe") {
                    mstore(add(add(payload, 0x20), mul(i, 0x20)), commitment)
                }
            }

            address shard = address(new EntitlementCommitmentDataShardV1(payload));
            uint256 actualCodeSize;
            assembly ("memory-safe") {
                actualCodeSize := extcodesize(shard)
            }
            uint256 expectedCodeSize = payload.length + 1;
            if (actualCodeSize != expectedCodeSize) {
                revert InvalidShardCodeSize(expectedCodeSize, actualCodeSize);
            }
            _dataShards.push(shard);
        }
    }

    /// @notice Returns an ordered commitment from immutable bytecode-backed data.
    function commitmentAt(uint256 index) external view returns (bytes32 commitment) {
        uint256 count = entitlementCount;
        if (index >= count) revert EntitlementIndexOutOfBounds(index, count);

        address shard = _dataShards[index / shardSize];
        uint256 byteOffset = 1 + (index % shardSize) * 32;
        assembly ("memory-safe") {
            extcodecopy(shard, 0x00, byteOffset, 0x20)
            commitment := mload(0x00)
        }
    }

    /// @notice Physical deployment detail for diagnostics; not part of logical identity.
    function physicalShardCount() external view returns (uint256) {
        return _dataShards.length;
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
