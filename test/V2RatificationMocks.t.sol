// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {V2RatificationAssuranceMock, V2RatificationAllocatorMock} from "./mocks/V2RatificationMocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISourceBoundProRataAssuranceV2} from "../src/interfaces/ISourceBoundProRataAssuranceV2.sol";
import {IShortfallAllocatorV2} from "../src/interfaces/IShortfallAllocatorV2.sol";

contract V2RatificationMocksTest is Test {
    V2RatificationAssuranceMock assurance;
    V2RatificationAllocatorMock allocator;
    bytes32 constant OP = keccak256("op");
    bytes32 constant P = keccak256("prepared");
    bytes32 constant C = keccak256("commitment");
    bytes32 constant RECEIPT = keccak256("receipt");

    function setUp() public { assurance = new V2RatificationAssuranceMock(); allocator = new V2RatificationAllocatorMock(); }

    function test_AssuranceMockIsOneShotAndExact() public {
        assurance.configure(ISourceBoundProRataAssuranceV2.RatificationPayload(P, C, bytes32(uint256(1)), bytes32(uint256(2)), OP, RECEIPT));
        assurance.consumeForRatification(OP, P, C);
        vm.expectRevert(bytes("ASSURANCE_REPLAY"));
        assurance.consumeForRatification(OP, P, C);
    }

    function test_AllocatorMockExposesMalformedCreateAndFundingFailures() public {
        allocator.setModes(false, false, true);
        allocator.create(OP, bytes32(uint256(1)), bytes32(uint256(2)), IERC20(address(1)), 10, address(2));
        IShortfallAllocatorV2.Operation memory malformed = allocator.operation(OP);
        assertEq(malformed.amount, 11);
        allocator.setModes(false, true, false);
        vm.expectRevert(bytes("ALLOCATOR_FUND_REVERT"));
        allocator.fund(OP);
    }
}
