// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {IPrfStatementAdmission} from "../src/interfaces/IPrfStatementAdmission.sol";
import {ISP1Verifier} from "../src/verification/interfaces/ISP1Verifier.sol";
import {
    PrfSourceBoundEntitlementVerifierAdapterV1
} from "../src/verification/adapters/PrfSourceBoundEntitlementVerifierAdapterV1.sol";
import {SourceBoundProRataControllerV2} from "../src/applications/shortfall/SourceBoundProRataControllerV2.sol";
import {
    SourceBoundProRataEntitlementAssuranceV1
} from "../src/applications/shortfall/SourceBoundProRataEntitlementAssuranceV1.sol";
import {SourceBoundEntitlementV1Commitments} from "../src/verification/SourceBoundEntitlementV1Commitments.sol";
import {ShortfallV2Commitments} from "../src/verification/ShortfallV2Commitments.sol";

contract EntitlementAssuranceVerifierMock is ISP1Verifier {
    function verifyProof(bytes32, bytes calldata, bytes calldata) external pure {}
}

contract EntitlementAssuranceAdmissionMock is IPrfStatementAdmission {
    mapping(bytes32 => AdmissionReceipt) private _receipts;

    function setReceipt(bytes32 id, AdmissionReceipt calldata receipt) external {
        _receipts[id] = receipt;
    }

    function admissionReceipt(bytes32 id) external view returns (AdmissionReceipt memory) {
        return _receipts[id];
    }

    function protocolGenesisRoot() external pure returns (bytes32) {
        return bytes32(0);
    }

    function chainInstanceGenesisRoot() external pure returns (bytes32) {
        return bytes32(0);
    }

    function expectedConfigurationRoot() external pure returns (bytes32) {
        return bytes32(0);
    }

    function expectedConfigurationEpoch() external pure returns (uint64) {
        return 0;
    }

    function admittedCount() external pure returns (uint256) {
        return 0;
    }

    function admitStatement(bytes32, bytes32, bytes calldata, bytes calldata) external pure returns (bytes32) {
        revert("NOT_USED");
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}

contract EntitlementAssuranceConsumerMock {
    function consume(
        SourceBoundProRataEntitlementAssuranceV1 assurance,
        bytes32 operationId,
        bytes32 preparedRoot,
        bytes32 reserveCommitment
    ) external returns (SourceBoundProRataEntitlementAssuranceV1.RatificationPayload memory) {
        return assurance.consumeForRatification(operationId, preparedRoot, reserveCommitment);
    }
}

contract SourceBoundProRataEntitlementAssuranceV1Test is Test {
    bytes32 private constant OPERATION = keccak256("entitlement-assurance-operation");
    bytes32 private constant RECEIPT = keccak256("entitlement-assurance-receipt");
    bytes32 private constant RESERVE = keccak256("entitlement-assurance-reserve");
    bytes32 private constant ALLOCATION = keccak256("entitlement-assurance-allocation");
    bytes32 private constant TABLE = keccak256("entitlement-assurance-table");
    bytes32 private constant CLAIM = keccak256("entitlement-assurance-claim");

    EntitlementAssuranceAdmissionMock private admission;
    PrfSourceBoundEntitlementVerifierAdapterV1 private adapter;
    SourceBoundProRataControllerV2 private prepared;
    SourceBoundProRataEntitlementAssuranceV1 private assurance;
    EntitlementAssuranceConsumerMock private consumer;
    bytes32 private preparedRoot;
    bytes private publicValues;

    function setUp() public {
        admission = new EntitlementAssuranceAdmissionMock();
        adapter = new PrfSourceBoundEntitlementVerifierAdapterV1(
            new EntitlementAssuranceVerifierMock(), keccak256("entitlement-vkey"), keccak256("entitlement-elf")
        );
        prepared = new SourceBoundProRataControllerV2();
        assurance = new SourceBoundProRataEntitlementAssuranceV1(admission, adapter, prepared, address(this));
        consumer = new EntitlementAssuranceConsumerMock();

        SourceBoundEntitlementV1Commitments.PreparedOperation memory operation = _operation();
        preparedRoot = prepared.prepareEntitlementOperation(operation);
        assurance.bindRatificationController(address(consumer));

        publicValues = abi.encode(
            adapter.PUBLIC_VALUES_SCHEMA(),
            preparedRoot,
            RESERVE,
            ALLOCATION,
            adapter.EXPECTED_DESCRIPTOR_ROOT(),
            TABLE,
            uint256(2),
            uint256(90),
            CLAIM
        );
        admission.setReceipt(RECEIPT, _receipt(publicValues));
    }

    function test_PrepareAndConsumePreservesAllSuccessorRoots() public {
        SourceBoundProRataEntitlementAssuranceV1.PreparedEntitlementAssurance memory stored =
            assurance.prepareSourceAssurance(OPERATION, RECEIPT, publicValues);
        assertEq(stored.preparedOperationRoot, preparedRoot);
        assertEq(stored.reserveStateCommitment, RESERVE);
        assertEq(stored.allocationBindingRoot, ALLOCATION);
        assertEq(stored.evmEntitlementTableRoot, TABLE);
        assertEq(stored.entitlementCount, 2);
        assertEq(stored.entitlementTotal, 90);
        assertEq(stored.allocationClaimRoot, CLAIM);

        SourceBoundProRataEntitlementAssuranceV1.RatificationPayload memory payload =
            consumer.consume(assurance, OPERATION, preparedRoot, RESERVE);
        assertEq(payload.operationId, OPERATION);
        assertEq(payload.receiptId, RECEIPT);
        assertEq(payload.evmEntitlementTableRoot, TABLE);
        assertEq(payload.entitlementCount, 2);
        assertEq(payload.entitlementTotal, 90);
        assertEq(payload.allocationClaimRoot, CLAIM);
        assertTrue(assurance.consumedAssurance(RECEIPT));
    }

    function test_RejectsStaleReserveCommitmentAtRatificationHandoff() public {
        assurance.prepareSourceAssurance(OPERATION, RECEIPT, publicValues);
        vm.expectRevert(SourceBoundProRataEntitlementAssuranceV1.InvalidPublicValues.selector);
        consumer.consume(assurance, OPERATION, preparedRoot, keccak256("stale-reserve-state"));
        assertFalse(assurance.consumedAssurance(RECEIPT));
        assertEq(
            uint8(assurance.preparedAssurance(OPERATION).state),
            uint8(SourceBoundProRataEntitlementAssuranceV1.State.Prepared)
        );
    }

    function test_RejectsDuplicateAssuranceConsumption() public {
        assurance.prepareSourceAssurance(OPERATION, RECEIPT, publicValues);
        consumer.consume(assurance, OPERATION, preparedRoot, RESERVE);
        vm.expectRevert(SourceBoundProRataEntitlementAssuranceV1.InvalidPreparedOperation.selector);
        consumer.consume(assurance, OPERATION, preparedRoot, RESERVE);
        assertTrue(assurance.consumedAssurance(RECEIPT));
    }

    function test_RejectsAdmissionStatementRootDifferentFromAllocationBindingRoot() public {
        IPrfStatementAdmission.AdmissionReceipt memory receipt = _receipt(publicValues);
        receipt.statementRoot = keccak256("other-allocation-binding");
        admission.setReceipt(RECEIPT, receipt);
        vm.expectRevert(SourceBoundProRataEntitlementAssuranceV1.StatementMismatch.selector);
        assurance.prepareSourceAssurance(OPERATION, RECEIPT, publicValues);
    }

    function test_RejectsLegacyPreparedOperation() public {
        bytes32 legacyOperation = keccak256("legacy-operation");
        vm.prank(address(0x1234));
        prepared.prepareOperation(_legacyOperation());
        bytes32 legacyRoot = prepared.preparedOperationRoot(legacyOperation);
        bytes memory legacyValues = abi.encode(
            adapter.PUBLIC_VALUES_SCHEMA(),
            legacyRoot,
            RESERVE,
            ALLOCATION,
            adapter.EXPECTED_DESCRIPTOR_ROOT(),
            TABLE,
            uint256(2),
            uint256(90),
            CLAIM
        );
        bytes32 legacyReceipt = keccak256("legacy-receipt");
        admission.setReceipt(legacyReceipt, _receipt(legacyValues));
        vm.expectRevert(SourceBoundProRataEntitlementAssuranceV1.InvalidPreparedOperation.selector);
        assurance.prepareSourceAssurance(legacyOperation, legacyReceipt, legacyValues);
    }

    function test_RejectsPreparedRootSubstitution() public {
        bytes memory substituted = abi.encode(
            adapter.PUBLIC_VALUES_SCHEMA(),
            bytes32(uint256(123)),
            RESERVE,
            ALLOCATION,
            adapter.EXPECTED_DESCRIPTOR_ROOT(),
            TABLE,
            uint256(2),
            uint256(90),
            CLAIM
        );
        bytes32 substitutedReceipt = keccak256("substituted-receipt");
        admission.setReceipt(substitutedReceipt, _receipt(substituted));
        vm.expectRevert(SourceBoundProRataEntitlementAssuranceV1.InvalidPublicValues.selector);
        assurance.prepareSourceAssurance(OPERATION, substitutedReceipt, substituted);
    }

    function test_RejectsAdmissionConfigurationRootDifferentFromPreparedOperation() public {
        IPrfStatementAdmission.AdmissionReceipt memory receipt = _receipt(publicValues);
        receipt.configurationRoot = keccak256("other-configuration");
        admission.setReceipt(RECEIPT, receipt);
        vm.expectRevert(SourceBoundProRataEntitlementAssuranceV1.InvalidIdentity.selector);
        assurance.prepareSourceAssurance(OPERATION, RECEIPT, publicValues);
    }

    function test_RejectsAdmissionConfigurationEpochDifferentFromPreparedOperation() public {
        IPrfStatementAdmission.AdmissionReceipt memory receipt = _receipt(publicValues);
        receipt.configurationEpoch = 8;
        admission.setReceipt(RECEIPT, receipt);
        vm.expectRevert(SourceBoundProRataEntitlementAssuranceV1.InvalidIdentity.selector);
        assurance.prepareSourceAssurance(OPERATION, RECEIPT, publicValues);
    }

    function test_RejectsVerifierIdentityDifferentFromPreparedOperation() public {
        IPrfStatementAdmission.AdmissionReceipt memory receipt = _receipt(publicValues);
        receipt.verifierId = keccak256("other-verifier");
        admission.setReceipt(RECEIPT, receipt);
        vm.expectRevert(SourceBoundProRataEntitlementAssuranceV1.InvalidIdentity.selector);
        assurance.prepareSourceAssurance(OPERATION, RECEIPT, publicValues);
    }

    function _receipt(bytes memory values) private view returns (IPrfStatementAdmission.AdmissionReceipt memory r) {
        r.exists = true;
        r.configurationRoot = keccak256("configuration");
        r.configurationEpoch = 7;
        r.verifierId = keccak256("verifier");
        r.verifierAdapter = address(adapter);
        r.programVKey = adapter.programVKey();
        r.programElfSha256 = adapter.programElfSha256();
        r.statementSchemaVersionHash = adapter.statementSchemaVersion();
        r.publicValuesSchema = adapter.publicValuesSchema();
        r.statementRoot = ALLOCATION;
        r.publicValuesDigest = sha256(values);
    }

    function _operation() private view returns (SourceBoundEntitlementV1Commitments.PreparedOperation memory op) {
        op.operationId = OPERATION;
        op.initiator = address(this);
        op.chainId = uint64(block.chainid);
        op.reserve = address(0x1111);
        op.token = address(0x2222);
        op.allocator = address(0x3333);
        op.configurationRoot = keccak256("configuration");
        op.configurationEpoch = 7;
        op.sourceVerifierId = keccak256("verifier");
        op.executionVerifierId = keccak256("execution-verifier");
        op.sourceProgramVKey = adapter.programVKey();
        op.sourceProgramElfSha256 = adapter.programElfSha256();
        op.sourceStatementSchema = adapter.statementSchemaVersion();
        op.sourcePublicValuesSchema = adapter.publicValuesSchema();
        op.executionStatementSchema = keccak256("execution-statement");
        op.executionPublicValuesSchema = keccak256("execution-public-values");
        op.policyRoot = keccak256("policy");
        op.beneficiaryProfile = SourceBoundEntitlementV1Commitments.BeneficiaryProfile.SmartAccountV1;
        op.residualRecipient = address(0x4444);
    }

    function _legacyOperation() private view returns (ShortfallV2Commitments.PreparedOperation memory op) {
        op.operationId = keccak256("legacy-operation");
        op.initiator = bytes32(uint256(uint160(address(0x1234))));
        op.chainId = uint64(block.chainid);
        op.reserve = bytes32(uint256(uint160(address(0x1111))));
        op.token = bytes32(uint256(uint160(address(0x2222))));
        op.allocator = bytes32(uint256(uint160(address(0x3333))));
        op.configurationRoot = keccak256("configuration");
        op.configurationEpoch = 7;
        op.sourceVerifierId = keccak256("source-verifier");
        op.executionVerifierId = keccak256("execution-verifier");
        op.sourceProgramVKey = keccak256("source-vkey");
        op.sourceProgramElfSha256 = keccak256("source-elf");
        op.sourceStatementSchema = keccak256("source-statement");
        op.sourcePublicValuesSchema = keccak256("source-pv");
        op.executionStatementSchema = keccak256("execution-statement");
        op.executionPublicValuesSchema = keccak256("execution-pv");
        op.policyRoot = keccak256("policy");
        op.residualRecipient = bytes32(uint256(uint160(address(0x4444))));
    }
}
