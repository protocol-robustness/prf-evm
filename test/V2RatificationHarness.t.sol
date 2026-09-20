// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ISourceBoundProRataAssuranceV2} from "../src/interfaces/ISourceBoundProRataAssuranceV2.sol";
import {V2RatificationAssuranceMock, V2RatificationAllocatorMock, V2ReentrantCallerMock} from "./mocks/V2RatificationMocks.sol";
import {V2RatificationHarness} from "./mocks/V2RatificationHarness.sol";

contract V2RatificationHarnessTest is Test {
    bytes32 constant OP = keccak256("op");
    bytes32 constant P = keccak256("prepared");
    bytes32 constant C = keccak256("commitment");
    bytes32 constant A = keccak256("allocation");
    bytes32 constant R = keccak256("realized");
    bytes32 constant RECEIPT = keccak256("receipt");
    V2RatificationAssuranceMock assurance;
    V2RatificationAllocatorMock allocator;
    V2RatificationHarness harness;

    function setUp() public {
        assurance = new V2RatificationAssuranceMock();
        allocator = new V2RatificationAllocatorMock();
        assurance.configure(ISourceBoundProRataAssuranceV2.RatificationPayload(P, C, A, R, OP, RECEIPT));
        harness = new V2RatificationHarness(OP, P, C, A, R, RECEIPT, assurance, allocator);
    }

    function test_SuccessConsumesAssuranceAndFundsAllocator() public {
        harness.ratifyAndFund(70);
        assertEq(uint8(harness.state()), uint8(V2RatificationHarness.State.Funded));
        assertTrue(assurance.consumed(RECEIPT));
    }

    function test_StaleAssuranceLeavesPreparedState() public {
        assurance.setShouldRevert(true);
        vm.expectRevert(bytes("ASSURANCE_REVERT"));
        harness.ratifyAndFund(70);
        assertEq(uint8(harness.state()), uint8(V2RatificationHarness.State.Prepared));
        assertFalse(assurance.consumed(RECEIPT));
    }

    function test_AllocatorCreateFailureRollsBackAssuranceAndState() public {
        allocator.setModes(true, false, false);
        vm.expectRevert(bytes("ALLOCATOR_CREATE_REVERT"));
        harness.ratifyAndFund(70);
        assertEq(uint8(harness.state()), uint8(V2RatificationHarness.State.Prepared));
        assertFalse(assurance.consumed(RECEIPT));
    }

    function test_AllocatorFundingFailureRollsBackAssuranceAndState() public {
        allocator.setModes(false, true, false);
        vm.expectRevert(bytes("ALLOCATOR_FUND_REVERT"));
        harness.ratifyAndFund(70);
        assertEq(uint8(harness.state()), uint8(V2RatificationHarness.State.Prepared));
        assertFalse(assurance.consumed(RECEIPT));
    }

    function test_ReentrantAllocatorCreateCannotReenterRatification() public {
        V2ReentrantCallerMock reentrant = new V2ReentrantCallerMock();
        reentrant.setTarget(address(harness));
        allocator.setReentryTarget(address(reentrant));
        harness.ratifyAndFund(70);
        assertTrue(reentrant.attempted());
        assertEq(uint8(harness.state()), uint8(V2RatificationHarness.State.Funded));
        assertTrue(assurance.consumed(RECEIPT));
    }

    function test_MalformedAllocatorCreateRollsBackAssuranceAndState() public {
        allocator.setModes(false, false, true);
        vm.expectRevert(V2RatificationHarness.AllocatorPostcondition.selector);
        harness.ratifyAndFund(70);
        assertEq(uint8(harness.state()), uint8(V2RatificationHarness.State.Prepared));
        assertFalse(assurance.consumed(RECEIPT));
    }
}
