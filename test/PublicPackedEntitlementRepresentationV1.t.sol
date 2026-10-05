// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {
    PublicPackedEntitlementRepresentationV1
} from "../src/applications/pro-rata/PublicPackedEntitlementRepresentationV1.sol";

contract PublicPackedEntitlementRepresentationV1Test is Test {
    bytes32 private constant NODE_DOMAIN = keccak256("prf.source-bound-entitlement.table-node.v1");
    bytes32 private constant ROOT_DOMAIN = keccak256("prf.source-bound-entitlement.table-root.v1");

    function test_ThreeOrderedCommitmentsUseDuplicateLastAndSummaryWords() public {
        bytes32[] memory values = new bytes32[](3);
        values[0] = keccak256("a");
        values[1] = keccak256("b");
        values[2] = keccak256("c");
        PublicPackedEntitlementRepresentationV1 table = new PublicPackedEntitlementRepresentationV1(values, 70);

        bytes32 ab = keccak256(abi.encodePacked(NODE_DOMAIN, values[0], values[1]));
        bytes32 cc = keccak256(abi.encodePacked(NODE_DOMAIN, values[2], values[2]));
        bytes32 members = keccak256(abi.encodePacked(NODE_DOMAIN, ab, cc));
        bytes32 expected = keccak256(abi.encodePacked(ROOT_DOMAIN, members, bytes32(uint256(3)), bytes32(uint256(70))));

        assertEq(table.logicalRoot(), expected);
        assertEq(table.entitlementCount(), 3);
        assertEq(table.entitlementTotal(), 70);
        assertEq(table.commitmentAt(0), values[0]);
        assertEq(table.commitmentAt(2), values[2]);
    }

    function test_RejectsEmptyOrZeroCommitments() public {
        vm.expectRevert(PublicPackedEntitlementRepresentationV1.EmptyEntitlementTable.selector);
        new PublicPackedEntitlementRepresentationV1(new bytes32[](0), 1);

        bytes32[] memory values = new bytes32[](1);
        vm.expectRevert(
            abi.encodeWithSelector(PublicPackedEntitlementRepresentationV1.ZeroEntitlementCommitment.selector, 0)
        );
        new PublicPackedEntitlementRepresentationV1(values, 1);
    }

    function test_PhysicalContainerIdentityDoesNotAffectLogicalRoot() public {
        bytes32[] memory values = new bytes32[](1);
        values[0] = keccak256("one");
        PublicPackedEntitlementRepresentationV1 first = new PublicPackedEntitlementRepresentationV1(values, 7);
        PublicPackedEntitlementRepresentationV1 second = new PublicPackedEntitlementRepresentationV1(values, 7);
        assertTrue(address(first) != address(second));
        assertEq(first.logicalRoot(), second.logicalRoot());
    }
}
