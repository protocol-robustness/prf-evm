// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ISourceBoundProRataAssuranceV2} from "../src/interfaces/ISourceBoundProRataAssuranceV2.sol";
import {SourceBoundProRataControllerV2} from "../src/applications/shortfall/SourceBoundProRataControllerV2.sol";
import {SourceBoundProRataAssuranceV2} from "../src/applications/shortfall/SourceBoundProRataAssuranceV2.sol";
import {SourceBoundProRataRatificationControllerV2} from "../src/applications/shortfall/SourceBoundProRataRatificationControllerV2.sol";
import {V2RatificationAssuranceMock, V2RatificationAllocatorMock} from "./mocks/V2RatificationMocks.sol";
import {V2RatificationReserveMock} from "./mocks/V2RatificationReserveMock.sol";
import {ShortfallV2Commitments} from "../src/verification/ShortfallV2Commitments.sol";

contract SourceBoundProRataRatificationControllerV2Test is Test {
    bytes32 constant OP = keccak256("op");
    bytes32 preparedRoot;
    bytes32 constant C = keccak256("commitment");
    bytes32 constant A = keccak256("allocation");
    bytes32 constant R = keccak256("realized");
    bytes32 constant RECEIPT = keccak256("receipt");
    SourceBoundProRataControllerV2 prepared;
    V2RatificationAssuranceMock assurance;
    V2RatificationReserveMock reserve;
    SourceBoundProRataRatificationControllerV2 controller;

    function setUp() public {
        prepared = new SourceBoundProRataControllerV2();
        assurance = new V2RatificationAssuranceMock();
        reserve = new V2RatificationReserveMock();
        preparedRoot = ShortfallV2Commitments.preparedOperationRoot(_operation(address(0x1111)));
        assurance.configure(ISourceBoundProRataAssuranceV2.RatificationPayload(preparedRoot, C, A, R, OP, RECEIPT));
        reserve.configure(C, false, 70, 18);
        controller = new SourceBoundProRataRatificationControllerV2(prepared, assurance, reserve);
        address initiator = address(0x1111);
        vm.prank(initiator);
        prepared.prepareOperation(_operation(initiator));
        controller.registerPrepared(OP);
    }

    function test_ControllerConsumesExactAssuranceAndTerminalizesFunded() public {
        controller.ratifyAndFund(OP, C, bytes32(uint256(4)), 1, address(0x2222));
        assertEq(uint8(controller.state(OP)), uint8(SourceBoundProRataRatificationControllerV2.State.Funded));
        assertTrue(assurance.consumed(RECEIPT));
        (,, uint256 funded,) = controller.result(OP);
                assertEq(funded, 70);
    }

    function test_ReserveFailureRestoresPreparedStateAndAssurance() public {
        reserve.configure(C, true, 70, 18);
        vm.expectRevert(bytes("RESERVE_RATIFICATION_REVERT"));
        controller.ratifyAndFund(OP, C, bytes32(uint256(4)), 1, address(0x2222));
        assertEq(uint8(controller.state(OP)), uint8(SourceBoundProRataRatificationControllerV2.State.Prepared));
        assertFalse(assurance.consumed(RECEIPT));
    }

    function _operation(address initiator) internal view returns (ShortfallV2Commitments.PreparedOperation memory operation) {
        operation = ShortfallV2Commitments.PreparedOperation({
            operationId: OP, initiator: bytes32(uint256(uint160(initiator))), chainId: uint64(block.chainid),
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
