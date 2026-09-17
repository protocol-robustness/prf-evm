// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {PrfStatementAdmissionTest} from "./PrfStatementAdmission.t.sol";
import {PrfStatementAdmission} from "../src/PrfStatementAdmission.sol";
import {PrfAssuredOperationConsumer} from "../src/PrfAssuredOperationConsumer.sol";
import {IPrfStatementAdmission} from "../src/interfaces/IPrfStatementAdmission.sol";

/// @notice End-to-end enforcement tests: proof admission is necessary but not
///         sufficient; the statement root must also match the precommitted operation.
contract PrfAssuredOperationConsumerTest is PrfStatementAdmissionTest {
    bytes32 internal constant OPERATION_A = keccak256("operation-a");
    bytes32 internal constant OPERATION_B = keccak256("operation-b");
    bytes32 internal constant OTHER_STATEMENT_ROOT = keccak256("other-statement");

    function _admitFixture() internal returns (bytes32) {
        return admission.admitStatement(
            REALIZED_ALLOC_VERIFIER_ID,
            FIXTURE_STATEMENT_ROOT,
            "",
            FIXTURE_PUBLIC_VALUES
        );
    }

    function _consumer() internal returns (PrfAssuredOperationConsumer) {
        return new PrfAssuredOperationConsumer(IPrfStatementAdmission(address(admission)), address(this));
    }

    function test_AdmissionReceipt_DigestIsDerivedFromVerifiedBytes() public {
        bytes32 receiptId = _admitFixture();
        IPrfStatementAdmission.AdmissionReceipt memory receipt = admission.admissionReceipt(receiptId);

        assertTrue(receipt.exists);
        assertEq(receipt.publicValuesDigest, sha256(FIXTURE_PUBLIC_VALUES));
        assertEq(receipt.statementRoot, FIXTURE_STATEMENT_ROOT);
        assertEq(receipt.configurationRoot, CONFIG_ROOT_0);
        assertEq(receipt.configurationEpoch, 0);
        assertEq(receipt.verifierId, REALIZED_ALLOC_VERIFIER_ID);
        assertEq(receipt.verifierAdapter, address(adapter));
        assertEq(receipt.programVKey, FIXTURE_VKEY);
        assertEq(receipt.programElfSha256, FIXTURE_ELF_SHA256);
        assertEq(receipt.statementSchemaVersionHash, keccak256("realized-allocation-statement.v1"));
        assertEq(receipt.publicValuesSchema, FIXTURE_PV_SCHEMA_HASH);
    }

    function test_ValidMatchingAdmission_AppliesOperationOnce() public {
        PrfAssuredOperationConsumer consumer = _consumer();
        consumer.createOperation(OPERATION_A, FIXTURE_STATEMENT_ROOT, CONFIG_ROOT_0, 0);
        bytes32 receiptId = _admitFixture();

        consumer.applyOperation(OPERATION_A, receiptId);

        PrfAssuredOperationConsumer.Operation memory op = consumer.operation(OPERATION_A);
        assertTrue(op.exists);
        assertTrue(op.applied);
        assertEq(op.expectedStatementRoot, FIXTURE_STATEMENT_ROOT);
        assertEq(op.admissionReceiptId, receiptId);
        assertTrue(consumer.consumptionUsed(op.consumptionId));
    }

    function test_NoAdmission_CannotApplyOperation() public {
        PrfAssuredOperationConsumer consumer = _consumer();
        consumer.createOperation(OPERATION_A, FIXTURE_STATEMENT_ROOT, CONFIG_ROOT_0, 0);

        vm.expectRevert(abi.encodeWithSelector(
            PrfAssuredOperationConsumer.UnknownAdmissionReceipt.selector,
            bytes32(uint256(1))
        ));
        consumer.applyOperation(OPERATION_A, bytes32(uint256(1)));
    }

    function test_AdmissionForDifferentStatement_CannotApplyOperation() public {
        PrfAssuredOperationConsumer consumer = _consumer();
        consumer.createOperation(OPERATION_A, OTHER_STATEMENT_ROOT, CONFIG_ROOT_0, 0);
        bytes32 receiptId = _admitFixture();

        vm.expectRevert(abi.encodeWithSelector(
            PrfAssuredOperationConsumer.StatementRootMismatch.selector,
            OTHER_STATEMENT_ROOT,
            FIXTURE_STATEMENT_ROOT
        ));
        consumer.applyOperation(OPERATION_A, receiptId);
    }

    function test_ReceiptMayBeConsumedOncePerDistinctOperation_WhenRootsMatch() public {
        PrfAssuredOperationConsumer consumer = _consumer();
        consumer.createOperation(OPERATION_A, FIXTURE_STATEMENT_ROOT, CONFIG_ROOT_0, 0);
        consumer.createOperation(OPERATION_B, FIXTURE_STATEMENT_ROOT, CONFIG_ROOT_0, 0);
        bytes32 receiptId = _admitFixture();

        consumer.applyOperation(OPERATION_A, receiptId);
        consumer.applyOperation(OPERATION_B, receiptId);

        assertTrue(consumer.operation(OPERATION_A).applied);
        assertTrue(consumer.operation(OPERATION_B).applied);
        assertTrue(
            consumer.operation(OPERATION_A).consumptionId
                != consumer.operation(OPERATION_B).consumptionId
        );
    }

    function test_HistoricalAdmissionReceipt_RemainsUsableAfterConfigurationChanges() public {
        PrfAssuredOperationConsumer consumer = _consumer();
        consumer.createOperation(OPERATION_A, FIXTURE_STATEMENT_ROOT, CONFIG_ROOT_0, 0);
        bytes32 receiptId = _admitFixture();
        bytes32 nextConfigurationRoot = keccak256("next-configuration-root");
        bytes32 decisionRoot = keccak256("advance-configuration-after-admission");

        authority.authoriseDecision(
            decisionRoot,
            0,
            CHAIN_INSTANCE_ROOT,
            CONFIG_ROOT_0,
            nextConfigurationRoot,
            VERIFIER_REGISTRY_ROOT_0,
            VERIFIER_REGISTRY_ROOT_0,
            1
        );
        executor.applyConfiguration(
            decisionRoot,
            nextConfigurationRoot,
            VERIFIER_REGISTRY_ROOT_0,
            1,
            0,
            CHAIN_INSTANCE_ROOT,
            new bytes32[](0)
        );
        assertEq(executor.currentConfigurationRoot(), nextConfigurationRoot);

        consumer.applyOperation(OPERATION_A, receiptId);
        assertTrue(consumer.operation(OPERATION_A).applied);
    }

    function test_LaterSnapshotReceiptCannotSatisfyEarlierOperationPolicy() public {
        bytes32 nextConfigurationRoot = keccak256("next-configuration-root");
        bytes32 decisionRoot = keccak256("advance-configuration-for-new-admission");
        authority.authoriseDecision(
            decisionRoot,
            0,
            CHAIN_INSTANCE_ROOT,
            CONFIG_ROOT_0,
            nextConfigurationRoot,
            VERIFIER_REGISTRY_ROOT_0,
            VERIFIER_REGISTRY_ROOT_0,
            1
        );
        executor.applyConfiguration(
            decisionRoot,
            nextConfigurationRoot,
            VERIFIER_REGISTRY_ROOT_0,
            1,
            0,
            CHAIN_INSTANCE_ROOT,
            new bytes32[](0)
        );

        PrfStatementAdmission nextAdmission = new PrfStatementAdmission(
            genesis,
            executor,
            registry,
            nextConfigurationRoot,
            1
        );
        bytes32 nextReceiptId = nextAdmission.admitStatement(
            REALIZED_ALLOC_VERIFIER_ID,
            FIXTURE_STATEMENT_ROOT,
            "",
            FIXTURE_PUBLIC_VALUES
        );
        PrfAssuredOperationConsumer nextConsumer = new PrfAssuredOperationConsumer(
            IPrfStatementAdmission(address(nextAdmission)),
            address(this)
        );

        nextConsumer.createOperation(OPERATION_A, FIXTURE_STATEMENT_ROOT, CONFIG_ROOT_0, 0);
        vm.expectRevert(abi.encodeWithSelector(
            PrfAssuredOperationConsumer.ConfigurationRootMismatch.selector,
            CONFIG_ROOT_0,
            nextConfigurationRoot
        ));
        nextConsumer.applyOperation(OPERATION_A, nextReceiptId);

        nextConsumer.createOperation(OPERATION_B, FIXTURE_STATEMENT_ROOT, nextConfigurationRoot, 1);
        nextConsumer.applyOperation(OPERATION_B, nextReceiptId);
        assertTrue(nextConsumer.operation(OPERATION_B).applied);
    }

    function test_DuplicateOperationConsumption_Reverts() public {
        PrfAssuredOperationConsumer consumer = _consumer();
        consumer.createOperation(OPERATION_A, FIXTURE_STATEMENT_ROOT, CONFIG_ROOT_0, 0);
        bytes32 receiptId = _admitFixture();
        consumer.applyOperation(OPERATION_A, receiptId);

        vm.expectRevert(abi.encodeWithSelector(
            PrfAssuredOperationConsumer.OperationAlreadyApplied.selector,
            OPERATION_A
        ));
        consumer.applyOperation(OPERATION_A, receiptId);
    }

    function test_ExpectedStatementCannotBeMutatedOrReplaced() public {
        PrfAssuredOperationConsumer consumer = _consumer();
        consumer.createOperation(OPERATION_A, FIXTURE_STATEMENT_ROOT, CONFIG_ROOT_0, 0);

        vm.expectRevert(abi.encodeWithSelector(
            PrfAssuredOperationConsumer.OperationAlreadyExists.selector,
            OPERATION_A
        ));
        consumer.createOperation(OPERATION_A, OTHER_STATEMENT_ROOT, CONFIG_ROOT_0, 0);

        assertEq(consumer.operation(OPERATION_A).expectedStatementRoot, FIXTURE_STATEMENT_ROOT);
    }

    function test_OnlyOperationAuthorityCanCreateOperation() public {
        PrfAssuredOperationConsumer consumer = _consumer();
        address attacker = address(0xA11CE);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(
            PrfAssuredOperationConsumer.OnlyOperationAuthority.selector,
            attacker,
            address(this)
        ));
        consumer.createOperation(OPERATION_A, FIXTURE_STATEMENT_ROOT, CONFIG_ROOT_0, 0);
    }
}
