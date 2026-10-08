// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ISourceBoundProRataAssuranceV2} from "../src/interfaces/ISourceBoundProRataAssuranceV2.sol";
import {ProductionProRataAllocatorV2} from "../src/applications/pro-rata/ProductionProRataAllocatorV2.sol";
import {OnchainShortfallReserveV2} from "../src/applications/shortfall/OnchainShortfallReserveV2.sol";
import {V2ReserveToken} from "./OnchainShortfallReserveV2.t.sol";
import {SourceBoundProRataControllerV2} from "../src/applications/shortfall/SourceBoundProRataControllerV2.sol";
import {SourceBoundProRataAssuranceV2} from "../src/applications/shortfall/SourceBoundProRataAssuranceV2.sol";
import {
    SourceBoundProRataRatificationControllerV2
} from "../src/applications/shortfall/SourceBoundProRataRatificationControllerV2.sol";
import {V2RatificationAssuranceMock, V2RatificationAllocatorMock} from "./mocks/V2RatificationMocks.sol";
import {V2RatificationReserveMock} from "./mocks/V2RatificationReserveMock.sol";
import {ShortfallV2Commitments} from "../src/verification/ShortfallV2Commitments.sol";
import {SourceBoundEntitlementV1Commitments} from "../src/verification/SourceBoundEntitlementV1Commitments.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IShortfallAllocatorV2} from "../src/interfaces/IShortfallAllocatorV2.sol";

contract SourceBoundProRataRatificationControllerV2Test is Test {
    bytes32 constant OP = keccak256("op");
    bytes32 constant OP_SUCCESSOR = keccak256("op-successor");
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
        reserve.configureDeploymentIdentity(IERC20(address(0x2222)), IShortfallAllocatorV2(address(0x3333)));
        preparedRoot = ShortfallV2Commitments.preparedOperationRoot(_operation(address(0x1111)));
        assurance.configure(ISourceBoundProRataAssuranceV2.RatificationPayload(preparedRoot, C, A, R, OP, RECEIPT));
        reserve.configure(C, false, 70, 18);
        controller = new SourceBoundProRataRatificationControllerV2(prepared, assurance, reserve);
        prepared.bindRatificationController(address(controller));
        controller.bindExecutionCaller(address(this));
        address initiator = address(0x1111);
        ShortfallV2Commitments.PreparedOperation memory operation = _operation(initiator);
        vm.prank(initiator);
        prepared.prepareOperation(operation);
        controller.registerPrepared(OP);
    }

    function test_ExecutionCallerBindingIsGovernedAndPermanent() public {
        assertEq(controller.executionCaller(), address(this));
        assertTrue(controller.executionCallerBound());

        vm.prank(address(0xBAD));
        vm.expectRevert(
            abi.encodeWithSelector(SourceBoundProRataRatificationControllerV2.OnlyGovernance.selector, address(0xBAD))
        );
        controller.bindExecutionCaller(address(this));

        vm.expectRevert(SourceBoundProRataRatificationControllerV2.ExecutionCallerAlreadyBound.selector);
        controller.bindExecutionCaller(address(this));
    }

    function test_ControllerConsumesExactAssuranceAndTerminalizesFunded() public {
        controller.ratifyAndFund(OP, C, bytes32(uint256(4)), 1, address(0x2222));
        assertEq(uint8(controller.state(OP)), uint8(SourceBoundProRataRatificationControllerV2.State.Funded));
        assertTrue(assurance.consumed(RECEIPT));
        assertEq(uint8(prepared.state(OP)), uint8(SourceBoundProRataControllerV2.State.Ratified));
        (,, uint256 funded,) = controller.result(OP);
        assertEq(funded, 70);
    }

    function test_ReserveFailureRestoresPreparedStateAndAssurance() public {
        reserve.configure(C, true, 70, 18);
        vm.expectRevert(bytes("RESERVE_RATIFICATION_REVERT"));
        controller.ratifyAndFund(OP, C, bytes32(uint256(4)), 1, address(0x2222));
        assertEq(uint8(controller.state(OP)), uint8(SourceBoundProRataRatificationControllerV2.State.Prepared));
        assertFalse(assurance.consumed(RECEIPT));
        assertEq(uint8(prepared.state(OP)), uint8(SourceBoundProRataControllerV2.State.Prepared));
    }

    function test_AbandonBeforeRatificationPreventsFunding() public {
        vm.prank(address(0x1111));
        prepared.abandonPreparedOperation(OP);
        vm.expectRevert(
            abi.encodeWithSelector(
                SourceBoundProRataRatificationControllerV2.InvalidPreparedOperation.selector,
                SourceBoundProRataControllerV2.State.Abandoned
            )
        );
        controller.ratifyAndFund(OP, C, bytes32(uint256(4)), 1, address(0x2222));
        assertEq(uint8(prepared.state(OP)), uint8(SourceBoundProRataControllerV2.State.Abandoned));
        assertEq(uint8(controller.state(OP)), uint8(SourceBoundProRataRatificationControllerV2.State.Prepared));
    }

    function test_RatificationRejectsConfigurationEpochOrRecipientSubstitution() public {
        vm.expectRevert(SourceBoundProRataRatificationControllerV2.PreparedContextMismatch.selector);
        controller.ratifyAndFund(OP, C, bytes32(uint256(99)), 1, address(0x2222));

        vm.expectRevert(SourceBoundProRataRatificationControllerV2.PreparedContextMismatch.selector);
        controller.ratifyAndFund(OP, C, bytes32(uint256(4)), 2, address(0x2222));

        vm.expectRevert(SourceBoundProRataRatificationControllerV2.PreparedContextMismatch.selector);
        controller.ratifyAndFund(OP, C, bytes32(uint256(4)), 1, address(0x3333));

        assertEq(uint8(controller.state(OP)), uint8(SourceBoundProRataRatificationControllerV2.State.Prepared));
        assertFalse(assurance.consumed(RECEIPT));
    }

    function test_SuccessorRejectsPreparedReserveDifferentFromFundedReserve() public {
        _prepareSuccessor(OP_SUCCESSOR, address(0x9999), address(0x2222), address(0x3333));
        reserve.configureDeploymentIdentity(IERC20(address(0x2222)), IShortfallAllocatorV2(address(0x3333)));

        vm.expectRevert(SourceBoundProRataRatificationControllerV2.PreparedContextMismatch.selector);
        controller.ratifyAndFund(OP_SUCCESSOR, C, bytes32(uint256(4)), 1, address(0x2222));
        assertFalse(assurance.consumed(RECEIPT));
    }

    function test_SuccessorRejectsPreparedTokenDifferentFromFundedToken() public {
        _prepareSuccessor(OP_SUCCESSOR, address(reserve), address(0x9999), address(0x3333));
        reserve.configureDeploymentIdentity(IERC20(address(0x2222)), IShortfallAllocatorV2(address(0x3333)));

        vm.expectRevert(SourceBoundProRataRatificationControllerV2.PreparedContextMismatch.selector);
        controller.ratifyAndFund(OP_SUCCESSOR, C, bytes32(uint256(4)), 1, address(0x2222));
        assertFalse(assurance.consumed(RECEIPT));
    }

    function test_SuccessorRejectsPreparedAllocatorDifferentFromFundedAllocator() public {
        _prepareSuccessor(OP_SUCCESSOR, address(reserve), address(0x2222), address(0x9999));
        reserve.configureDeploymentIdentity(IERC20(address(0x2222)), IShortfallAllocatorV2(address(0x3333)));

        vm.expectRevert(SourceBoundProRataRatificationControllerV2.PreparedContextMismatch.selector);
        controller.ratifyAndFund(OP_SUCCESSOR, C, bytes32(uint256(4)), 1, address(0x2222));
        assertFalse(assurance.consumed(RECEIPT));
    }

    function test_SuccessorAcceptsPreparedDeploymentIdentityMatchingReserve() public {
        _prepareSuccessor(OP_SUCCESSOR, address(reserve), address(0x2222), address(0x3333));
        reserve.configureDeploymentIdentity(IERC20(address(0x2222)), IShortfallAllocatorV2(address(0x3333)));

        controller.ratifyAndFund(OP_SUCCESSOR, C, bytes32(uint256(4)), 1, address(0x2222));
        assertTrue(assurance.consumed(RECEIPT));
        assertEq(uint8(prepared.state(OP_SUCCESSOR)), uint8(SourceBoundProRataControllerV2.State.Ratified));
    }

    function _prepareSuccessor(
        bytes32 operationId,
        address reserveAddress,
        address tokenAddress,
        address allocatorAddress
    ) internal {
        SourceBoundEntitlementV1Commitments.PreparedOperation memory operation;
        operation.operationId = operationId;
        operation.initiator = address(0x1111);
        operation.chainId = uint128(block.chainid);
        operation.reserve = reserveAddress;
        operation.token = tokenAddress;
        operation.allocator = allocatorAddress;
        operation.configurationRoot = bytes32(uint256(4));
        operation.configurationEpoch = 1;
        operation.sourceVerifierId = bytes32(uint256(5));
        operation.sourceProgramVKey = bytes32(uint256(7));
        operation.sourceProgramElfSha256 = bytes32(uint256(8));
        operation.sourceStatementSchema = bytes32(uint256(9));
        operation.sourcePublicValuesSchema = bytes32(uint256(10));
        operation.beneficiaryProfile = SourceBoundEntitlementV1Commitments.BeneficiaryProfile.SmartAccountV1;
        operation.residualRecipient = address(0x2222);

        vm.prank(operation.initiator);
        bytes32 root = prepared.prepareEntitlementOperation(operation);
        assurance.configure(ISourceBoundProRataAssuranceV2.RatificationPayload(root, C, A, R, operationId, RECEIPT));
        controller.registerPrepared(operationId);
    }

    function test_RatificationFirstMakesPreparedOperationNonAbandonable() public {
        controller.ratifyAndFund(OP, C, bytes32(uint256(4)), 1, address(0x2222));
        vm.prank(address(0x1111));
        vm.expectRevert(
            abi.encodeWithSelector(
                SourceBoundProRataControllerV2.InvalidState.selector, SourceBoundProRataControllerV2.State.Ratified
            )
        );
        prepared.abandonPreparedOperation(OP);
    }

    function test_LegacyFundCancelRefundRestoresReserveAccountingEndToEnd() public {
        V2ReserveToken liveToken = new V2ReserveToken();
        ProductionProRataAllocatorV2 liveAllocator = new ProductionProRataAllocatorV2(address(this));
        OnchainShortfallReserveV2 liveReserve =
            new OnchainShortfallReserveV2(liveToken, address(this), 10, liveAllocator);
        SourceBoundProRataControllerV2 livePrepared = new SourceBoundProRataControllerV2();
        V2RatificationAssuranceMock liveAssurance = new V2RatificationAssuranceMock();
        SourceBoundProRataRatificationControllerV2 liveController =
            new SourceBoundProRataRatificationControllerV2(livePrepared, liveAssurance, liveReserve);
        liveAllocator.bindFundingAuthority(address(liveReserve));
        liveReserve.bindRatificationAuthority(address(liveController));
        livePrepared.bindRatificationController(address(liveController));
        liveController.bindExecutionCaller(address(this));

        liveToken.mint(address(this), 100);
        liveToken.approve(address(liveReserve), 100);
        liveReserve.deposit(100);

        bytes32 operationId = keccak256("legacy-cancel-refund-roundtrip");
        bytes32 allocationRoot = keccak256("legacy-cancel-refund-allocation");
        bytes32 statementRoot = keccak256("legacy-cancel-refund-statement");
        bytes32 configurationRoot = keccak256("legacy-cancel-refund-configuration");
        address residual = address(0x4444);
        ShortfallV2Commitments.PreparedOperation memory operation = ShortfallV2Commitments.PreparedOperation({
            operationId: operationId,
            initiator: bytes32(uint256(uint160(address(this)))),
            chainId: uint64(block.chainid),
            reserve: bytes32(uint256(uint160(address(liveReserve)))),
            token: bytes32(uint256(uint160(address(liveToken)))),
            allocator: bytes32(uint256(uint160(address(liveAllocator)))),
            configurationRoot: configurationRoot,
            configurationEpoch: 1,
            sourceVerifierId: keccak256("source-verifier"),
            executionVerifierId: keccak256("execution-verifier"),
            sourceProgramVKey: keccak256("source-vkey"),
            sourceProgramElfSha256: keccak256("source-elf"),
            sourceStatementSchema: keccak256("source-statement"),
            sourcePublicValuesSchema: keccak256("source-values"),
            executionStatementSchema: keccak256("execution-statement"),
            executionPublicValuesSchema: keccak256("execution-values"),
            policyRoot: keccak256("policy"),
            residualRecipient: bytes32(uint256(uint160(residual)))
        });
        bytes32 root = livePrepared.prepareOperation(operation);
        bytes32 commitment = liveReserve.economicState(root).commitment;
        bytes32 receiptId = keccak256("legacy-cancel-refund-receipt");
        liveAssurance.configure(
            ISourceBoundProRataAssuranceV2.RatificationPayload(
                root, commitment, allocationRoot, statementRoot, operationId, receiptId
            )
        );
        liveController.registerPrepared(operationId);
        liveController.ratifyAndFund(operationId, commitment, configurationRoot, 1, residual);
        assertEq(liveToken.balanceOf(address(liveReserve)), 10);
        assertEq(liveToken.balanceOf(address(liveAllocator)), 90);
        assertEq(liveToken.allowance(address(liveReserve), address(liveAllocator)), 0);

        liveController.cancelAndRefund(operationId);
        IShortfallAllocatorV2.Operation memory refunded = liveAllocator.operation(operationId);
        assertEq(uint8(refunded.state), uint8(IShortfallAllocatorV2.State.Cancelled));
        assertEq(liveAllocator.fundingSource(operationId), address(liveReserve));
        assertEq(
            uint8(liveController.state(operationId)),
            uint8(SourceBoundProRataRatificationControllerV2.State.CancelledRefunded)
        );
        assertEq(uint8(livePrepared.state(operationId)), uint8(SourceBoundProRataControllerV2.State.Ratified));
        assertEq(liveToken.balanceOf(address(liveReserve)), 100);
        assertEq(liveToken.balanceOf(address(liveAllocator)), 0);
        assertEq(liveToken.allowance(address(liveReserve), address(liveAllocator)), 0);
        assertEq(liveReserve.totalReserved(), 0);
        assertEq(liveReserve.availabilityRevision(), 2);
        assertEq(liveReserve.economicState(root).availableAmount, 90);
        assertEq(liveReserve.nextSnapshotId(), 2);
        assertFalse(liveReserve.ratifying());

        vm.expectRevert(
            abi.encodeWithSelector(
                SourceBoundProRataRatificationControllerV2.InvalidState.selector,
                SourceBoundProRataRatificationControllerV2.State.CancelledRefunded
            )
        );
        liveController.cancelAndRefund(operationId);
    }

    function test_LegacyDeclaredWrongChainAndAllocatorRejectBeforeConsumption() public {
        ShortfallV2Commitments.PreparedOperation memory wrongChain = _operation(address(0x1111));
        wrongChain.operationId = keccak256("wrong-chain");
        wrongChain.chainId = uint64(block.chainid + 1);
        _assertRejectedScope(wrongChain);

        ShortfallV2Commitments.PreparedOperation memory wrongAllocator = _operation(address(0x1111));
        wrongAllocator.operationId = keccak256("wrong-allocator");
        wrongAllocator.allocator = bytes32(uint256(uint160(address(0xBAD))));
        _assertRejectedScope(wrongAllocator);
    }

    function test_DifferentControllerInstanceRejectsBeforeConsumption() public {
        SourceBoundProRataRatificationControllerV2 other =
            new SourceBoundProRataRatificationControllerV2(prepared, assurance, reserve);
        other.bindExecutionCaller(address(this));
        other.registerPrepared(OP);
        vm.expectRevert(SourceBoundProRataRatificationControllerV2.PreparedContextMismatch.selector);
        other.ratifyAndFund(OP, C, bytes32(uint256(4)), 1, address(0x2222));
        assertEq(uint8(other.state(OP)), uint8(SourceBoundProRataRatificationControllerV2.State.Prepared));
        assertFalse(assurance.consumed(RECEIPT));
        assertEq(uint8(controller.state(OP)), uint8(SourceBoundProRataRatificationControllerV2.State.Prepared));
    }

    function _assertRejectedScope(ShortfallV2Commitments.PreparedOperation memory operation) private {
        vm.prank(address(0x1111));
        bytes32 root = prepared.prepareOperation(operation);
        controller.registerPrepared(operation.operationId);
        vm.expectRevert(SourceBoundProRataRatificationControllerV2.PreparedContextMismatch.selector);
        controller.ratifyAndFund(operation.operationId, C, bytes32(uint256(4)), 1, address(0x2222));
        assertEq(uint8(prepared.state(operation.operationId)), uint8(SourceBoundProRataControllerV2.State.Prepared));
        assertEq(
            uint8(controller.state(operation.operationId)),
            uint8(SourceBoundProRataRatificationControllerV2.State.Prepared)
        );
        assertFalse(assurance.consumed(RECEIPT));
        assertEq(prepared.preparedOperationRoot(operation.operationId), root);
    }

    function _operation(address initiator)
        internal
        view
        returns (ShortfallV2Commitments.PreparedOperation memory operation)
    {
        operation = ShortfallV2Commitments.PreparedOperation({
            operationId: OP,
            initiator: bytes32(uint256(uint160(initiator))),
            chainId: uint64(block.chainid),
            reserve: bytes32(uint256(uint160(address(reserve)))),
            token: bytes32(uint256(uint160(address(reserve.token())))),
            allocator: bytes32(uint256(uint160(address(reserve.allocator())))),
            configurationRoot: bytes32(uint256(4)),
            configurationEpoch: 1,
            sourceVerifierId: bytes32(uint256(5)),
            executionVerifierId: bytes32(uint256(6)),
            sourceProgramVKey: bytes32(uint256(7)),
            sourceProgramElfSha256: bytes32(uint256(8)),
            sourceStatementSchema: bytes32(uint256(9)),
            sourcePublicValuesSchema: bytes32(uint256(10)),
            executionStatementSchema: bytes32(uint256(11)),
            executionPublicValuesSchema: bytes32(uint256(12)),
            policyRoot: bytes32(uint256(13)),
            residualRecipient: bytes32(uint256(uint160(address(0x2222))))
        });
    }
}
