// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {
    CommittedImmutableEntitlementRepresentationV1
} from "../src/applications/pro-rata/CommittedImmutableEntitlementRepresentationV1.sol";
import {
    PublicPackedEntitlementRepresentationV1
} from "../src/applications/pro-rata/PublicPackedEntitlementRepresentationV1.sol";

contract CommittedImmutableEntitlementRepresentationV1Test is Test {
    function test_PhysicalShardingDoesNotChangeLogicalRootOrOrderedCommitments() public {
        bytes32[] memory values = _commitments();
        PublicPackedEntitlementRepresentationV1 packedReference =
            new PublicPackedEntitlementRepresentationV1(values, 170);
        CommittedImmutableEntitlementRepresentationV1 onePerShard =
            new CommittedImmutableEntitlementRepresentationV1(values, 170, 1);
        CommittedImmutableEntitlementRepresentationV1 twoPerShard =
            new CommittedImmutableEntitlementRepresentationV1(values, 170, 2);
        CommittedImmutableEntitlementRepresentationV1 allInOneShard =
            new CommittedImmutableEntitlementRepresentationV1(values, 170, 767);

        assertEq(onePerShard.logicalRoot(), packedReference.logicalRoot());
        assertEq(twoPerShard.logicalRoot(), packedReference.logicalRoot());
        assertEq(allInOneShard.logicalRoot(), packedReference.logicalRoot());
        assertEq(onePerShard.entitlementCount(), packedReference.entitlementCount());
        assertEq(twoPerShard.entitlementTotal(), packedReference.entitlementTotal());
        assertEq(onePerShard.physicalShardCount(), 5);
        assertEq(twoPerShard.physicalShardCount(), 3);
        assertEq(allInOneShard.physicalShardCount(), 1);

        for (uint256 i; i < values.length; ++i) {
            assertEq(onePerShard.commitmentAt(i), values[i]);
            assertEq(twoPerShard.commitmentAt(i), values[i]);
            assertEq(allInOneShard.commitmentAt(i), values[i]);
        }
    }

    function test_RejectsEmptyZeroTotalAndZeroCommitment() public {
        vm.expectRevert(CommittedImmutableEntitlementRepresentationV1.EmptyEntitlementTable.selector);
        new CommittedImmutableEntitlementRepresentationV1(new bytes32[](0), 1, 1);

        vm.expectRevert(CommittedImmutableEntitlementRepresentationV1.EmptyEntitlementTable.selector);
        new CommittedImmutableEntitlementRepresentationV1(_commitments(), 0, 1);

        bytes32[] memory values = new bytes32[](1);
        vm.expectRevert(
            abi.encodeWithSelector(CommittedImmutableEntitlementRepresentationV1.ZeroEntitlementCommitment.selector, 0)
        );
        new CommittedImmutableEntitlementRepresentationV1(values, 1, 1);
    }

    function test_RejectsShardSizesOutsideRuntimeCodeLimit() public {
        bytes32[] memory values = _commitments();
        vm.expectRevert(
            abi.encodeWithSelector(CommittedImmutableEntitlementRepresentationV1.InvalidShardSize.selector, 0, 767)
        );
        new CommittedImmutableEntitlementRepresentationV1(values, 170, 0);

        vm.expectRevert(
            abi.encodeWithSelector(CommittedImmutableEntitlementRepresentationV1.InvalidShardSize.selector, 768, 767)
        );
        new CommittedImmutableEntitlementRepresentationV1(values, 170, 768);
    }

    function test_CommitmentReadRejectsIndexOutsideCanonicalCount() public {
        CommittedImmutableEntitlementRepresentationV1 table =
            new CommittedImmutableEntitlementRepresentationV1(_commitments(), 170, 2);
        vm.expectRevert(
            abi.encodeWithSelector(
                CommittedImmutableEntitlementRepresentationV1.EntitlementIndexOutOfBounds.selector, 5, 5
            )
        );
        table.commitmentAt(5);
    }

    function _commitments() private pure returns (bytes32[] memory values) {
        values = new bytes32[](5);
        values[0] = keccak256("entitlement-0");
        values[1] = keccak256("entitlement-1");
        values[2] = keccak256("entitlement-2");
        values[3] = keccak256("entitlement-3");
        values[4] = keccak256("entitlement-4");
    }
}
