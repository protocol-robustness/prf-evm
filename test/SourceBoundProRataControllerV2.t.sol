// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ShortfallV2Commitments} from "../src/verification/ShortfallV2Commitments.sol";
import {SourceBoundProRataControllerV2} from "../src/applications/shortfall/SourceBoundProRataControllerV2.sol";

contract SourceBoundProRataControllerV2Test is Test {
    SourceBoundProRataControllerV2 controller;
    address initiator = address(0x1111);
    bytes32 constant OPERATION = keccak256("operation");

    function setUp() public { controller = new SourceBoundProRataControllerV2(); }

    function test_PrepareFreezesIdentityWithoutCapitalReservation() public {
        ShortfallV2Commitments.PreparedOperation memory operation = _operation();
        vm.prank(initiator);
        bytes32 root = controller.prepareOperation(operation);
        assertEq(controller.preparedOperationRoot(OPERATION), root);
        assertEq(uint8(controller.state(OPERATION)), uint8(SourceBoundProRataControllerV2.State.Prepared));
        assertEq(controller.preparedInitiator(OPERATION), initiator);
    }

    function test_PreparationRequiresEncodedInitiator() public {
        ShortfallV2Commitments.PreparedOperation memory operation = _operation();
        vm.expectRevert();
        controller.prepareOperation(operation);
    }

    function test_PreparedOperationCanBeAbandonedWithoutReserveEffects() public {
        vm.prank(initiator);
        controller.prepareOperation(_operation());
        vm.prank(initiator);
        controller.abandonPreparedOperation(OPERATION);
        assertEq(uint8(controller.state(OPERATION)), uint8(SourceBoundProRataControllerV2.State.Abandoned));
    }

    function test_OperationIdCannotBePreparedTwice() public {
        vm.prank(initiator);
        controller.prepareOperation(_operation());
        vm.prank(initiator);
        vm.expectRevert(abi.encodeWithSelector(SourceBoundProRataControllerV2.OperationAlreadyExists.selector, OPERATION));
        controller.prepareOperation(_operation());
    }

    function _operation() internal view returns (ShortfallV2Commitments.PreparedOperation memory operation) {
        operation = ShortfallV2Commitments.PreparedOperation({
            operationId: OPERATION,
            initiator: bytes32(uint256(uint160(initiator))),
            chainId: uint64(block.chainid),
            reserve: bytes32(uint256(1)), token: bytes32(uint256(2)), allocator: bytes32(uint256(3)),
            configurationRoot: bytes32(uint256(4)), configurationEpoch: 1,
            sourceVerifierId: bytes32(uint256(5)), executionVerifierId: bytes32(uint256(6)),
            sourceProgramVKey: bytes32(uint256(7)), sourceProgramElfSha256: bytes32(uint256(8)),
            sourceStatementSchema: bytes32(uint256(9)), sourcePublicValuesSchema: bytes32(uint256(10)),
            executionStatementSchema: bytes32(uint256(11)), executionPublicValuesSchema: bytes32(uint256(12)),
            policyRoot: bytes32(uint256(13)), residualRecipient: bytes32(uint256(uint160(address(0x2222))))
        });
    }
}
