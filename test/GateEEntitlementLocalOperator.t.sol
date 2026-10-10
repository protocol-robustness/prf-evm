// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {GateEEntitlementLocalOperator} from "../script/RunGateEEntitlementLocal.s.sol";
import {
    SourceBoundProRataEntitlementRatificationControllerV1
} from "../src/applications/shortfall/SourceBoundProRataEntitlementRatificationControllerV1.sol";
import {IEntitlementRepresentationV1} from "../src/interfaces/IEntitlementRepresentationV1.sol";

contract GateEEntitlementLocalOperatorTest is Test {
    address private constant OWNER = address(0xA11CE);
    address private constant CONTROLLER = address(0xC011);
    bytes32 private constant OPERATION = bytes32(uint256(7));
    GateEEntitlementLocalOperator private operator;

    function setUp() public {
        vm.chainId(31337);
        operator = new GateEEntitlementLocalOperator(
            OWNER, OPERATION, SourceBoundProRataEntitlementRatificationControllerV1(CONTROLLER)
        );
    }

    function test_UnauthorizedCannotFundActivateOrRefund() public {
        vm.expectRevert("only operation operator");
        operator.fund(bytes32(uint256(1)), address(0xB));
        vm.expectRevert("only operation operator");
        operator.activate(IEntitlementRepresentationV1(address(0xD)));
        vm.expectRevert("only operation operator");
        operator.refund();
    }

    function test_ForwardingUsesBoundOperationOnly() public {
        bytes memory funding = abi.encodeCall(
            SourceBoundProRataEntitlementRatificationControllerV1.ratifyAndFund,
            (OPERATION, bytes32(uint256(1)), address(0xB))
        );
        vm.mockCall(CONTROLLER, funding, bytes(""));
        vm.expectCall(CONTROLLER, funding);
        vm.prank(OWNER);
        operator.fund(bytes32(uint256(1)), address(0xB));
        bytes memory activation = abi.encodeCall(
            SourceBoundProRataEntitlementRatificationControllerV1.activateEntitlement,
            (OPERATION, IEntitlementRepresentationV1(address(0xD)))
        );
        vm.mockCall(CONTROLLER, activation, bytes(""));
        vm.expectCall(CONTROLLER, activation);
        vm.prank(OWNER);
        operator.activate(IEntitlementRepresentationV1(address(0xD)));
        bytes memory refund = abi.encodeCall(
            SourceBoundProRataEntitlementRatificationControllerV1.cancelAndRefundEntitlement, (OPERATION)
        );
        vm.mockCall(CONTROLLER, refund, bytes(""));
        vm.expectCall(CONTROLLER, refund);
        vm.prank(OWNER);
        operator.refund();
    }

    function test_ControllerFailurePropagates() public {
        vm.mockCallRevert(
            CONTROLLER,
            abi.encodeWithSelector(
                SourceBoundProRataEntitlementRatificationControllerV1.cancelAndRefundEntitlement.selector
            ),
            abi.encodeWithSignature("Error(string)", "terminal")
        );
        vm.prank(OWNER);
        vm.expectRevert("terminal");
        operator.refund();
    }

    function test_RejectsNonlocalDeployment() public {
        vm.chainId(8453);
        vm.expectRevert("local chain only");
        new GateEEntitlementLocalOperator(
            OWNER, OPERATION, SourceBoundProRataEntitlementRatificationControllerV1(CONTROLLER)
        );
    }
}
