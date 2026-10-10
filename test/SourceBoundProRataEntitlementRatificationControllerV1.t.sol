// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPrfStatementAdmission} from "../src/interfaces/IPrfStatementAdmission.sol";
import {ISP1Verifier} from "../src/verification/interfaces/ISP1Verifier.sol";
import {IShortfallAllocatorV2} from "../src/interfaces/IShortfallAllocatorV2.sol";
import {ProductionProRataAllocatorV2} from "../src/applications/pro-rata/ProductionProRataAllocatorV2.sol";
import {MockEntitlementProofModeSource} from "./mocks/MockEntitlementProofModeSource.sol";
import {OnchainShortfallReserveV2} from "../src/applications/shortfall/OnchainShortfallReserveV2.sol";
import {SourceBoundProRataControllerV2} from "../src/applications/shortfall/SourceBoundProRataControllerV2.sol";
import {
    SourceBoundProRataEntitlementAssuranceV1
} from "../src/applications/shortfall/SourceBoundProRataEntitlementAssuranceV1.sol";
import {
    SourceBoundProRataEntitlementRatificationControllerV1
} from "../src/applications/shortfall/SourceBoundProRataEntitlementRatificationControllerV1.sol";
import {
    PrfSourceBoundEntitlementVerifierAdapterV1
} from "../src/verification/adapters/PrfSourceBoundEntitlementVerifierAdapterV1.sol";
import {SourceBoundEntitlementV1Commitments} from "../src/verification/SourceBoundEntitlementV1Commitments.sol";
import {IShortfallEntitlementAllocatorV1} from "../src/interfaces/IShortfallEntitlementAllocatorV1.sol";
import {IEntitlementRepresentationV1} from "../src/interfaces/IEntitlementRepresentationV1.sol";
import {
    PublicPackedEntitlementRepresentationV1
} from "../src/applications/pro-rata/PublicPackedEntitlementRepresentationV1.sol";
import {
    CommittedImmutableEntitlementRepresentationV1
} from "../src/applications/pro-rata/CommittedImmutableEntitlementRepresentationV1.sol";

contract EntitlementRatificationToken is ERC20 {
    constructor() ERC20("Entitlement Gate E", "EGE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract EntitlementRatificationVerifierMock is ISP1Verifier {
    function verifyProof(bytes32, bytes calldata, bytes calldata) external pure {}
}

contract EntitlementRatificationAdmissionMock is IPrfStatementAdmission {
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

contract SourceBoundProRataEntitlementRatificationControllerV1Test is Test {
    bytes32 private constant OPERATION = keccak256("successor-ratification-op");
    bytes32 private constant RECEIPT = keccak256("successor-ratification-receipt");
    bytes32 private constant ALLOCATION = keccak256("successor-ratification-allocation");
    bytes32 private TABLE;
    bytes32 private constant CLAIM = keccak256("successor-ratification-claim");
    address private constant RESIDUAL = address(0x4444);

    EntitlementRatificationToken private token;
    ProductionProRataAllocatorV2 private allocator;
    OnchainShortfallReserveV2 private reserve;
    SourceBoundProRataControllerV2 private prepared;
    SourceBoundProRataEntitlementAssuranceV1 private assurance;
    SourceBoundProRataEntitlementRatificationControllerV1 private ratification;
    EntitlementRatificationAdmissionMock private admission;
    PrfSourceBoundEntitlementVerifierAdapterV1 private adapter;
    PublicPackedEntitlementRepresentationV1 private representation;
    bytes32 private preparedRoot;
    bytes32 private reserveCommitment;

    function setUp() public {
        token = new EntitlementRatificationToken();
        token.mint(address(this), 100);
        allocator = new ProductionProRataAllocatorV2(address(this), new MockEntitlementProofModeSource());
        reserve = new OnchainShortfallReserveV2(token, address(this), 10, allocator);
        allocator.bindFundingAuthority(address(reserve));
        prepared = new SourceBoundProRataControllerV2();
        admission = new EntitlementRatificationAdmissionMock();
        adapter = new PrfSourceBoundEntitlementVerifierAdapterV1(
            new EntitlementRatificationVerifierMock(),
            keccak256("successor-ratification-vkey"),
            keccak256("successor-ratification-elf")
        );

        SourceBoundEntitlementV1Commitments.PreparedOperation memory op = _preparedOperation();
        preparedRoot = prepared.prepareEntitlementOperation(op);
        token.approve(address(reserve), 100);
        reserve.deposit(100);
        reserveCommitment = reserve.economicState(preparedRoot).commitment;

        bytes32[] memory commitments = new bytes32[](2);
        commitments[0] = keccak256("reference-entitlement-0");
        commitments[1] = keccak256("reference-entitlement-1");
        representation = new PublicPackedEntitlementRepresentationV1(commitments, 90);
        TABLE = representation.logicalRoot();

        assurance = new SourceBoundProRataEntitlementAssuranceV1(admission, adapter, prepared, address(this));
        ratification = new SourceBoundProRataEntitlementRatificationControllerV1(prepared, assurance, reserve);
        prepared.bindRatificationController(address(ratification));
        reserve.bindRatificationAuthority(address(ratification));
        assurance.bindRatificationController(address(ratification));
        ratification.bindExecutionCaller(address(this));
        _prepareProofTuple();
    }

    function test_RatifiesAndFundsTheExactAdmittedEntitlementTuple() public {
        assurance.prepareSourceAssurance(OPERATION, RECEIPT, _publicValues());
        ratification.registerPrepared(OPERATION);
        ratification.ratifyAndFund(OPERATION, reserveCommitment, RESIDUAL);

        IShortfallEntitlementAllocatorV1.EntitlementOperation memory op = allocator.entitlementOperation(OPERATION);
        assertEq(uint8(op.state), uint8(IShortfallAllocatorV2.State.Funded));
        assertEq(op.allocationBindingRoot, ALLOCATION);
        assertEq(op.descriptorRoot, adapter.EXPECTED_DESCRIPTOR_ROOT());
        assertEq(op.evmEntitlementTableRoot, TABLE);
        assertEq(op.entitlementCount, 2);
        assertEq(op.entitlementTotal, 90);
        assertEq(op.allocationClaimRoot, CLAIM);
        assertEq(op.amount, 90);
        assertEq(uint8(allocator.operation(OPERATION).state), uint8(IShortfallAllocatorV2.State.None));
        assertEq(uint8(prepared.state(OPERATION)), uint8(SourceBoundProRataControllerV2.State.Ratified));
        assertEq(
            uint8(ratification.state(OPERATION)),
            uint8(SourceBoundProRataEntitlementRatificationControllerV1.State.Funded)
        );
        assertTrue(assurance.consumedAssurance(RECEIPT));
        assertEq(token.balanceOf(address(reserve)), 10);
        assertEq(token.balanceOf(address(allocator)), 90);
        assertEq(reserve.totalReserved(), 0);
    }

    function test_StaleLiveReserveRollsBackAssuranceAndRatification() public {
        assurance.prepareSourceAssurance(OPERATION, RECEIPT, _publicValues());
        ratification.registerPrepared(OPERATION);
        token.mint(address(this), 1);
        token.approve(address(reserve), 1);
        reserve.deposit(1);

        vm.expectRevert(
            abi.encodeWithSelector(
                OnchainShortfallReserveV2.CommitmentMismatch.selector,
                reserveCommitment,
                reserve.economicState(preparedRoot).commitment
            )
        );
        ratification.ratifyAndFund(OPERATION, reserveCommitment, RESIDUAL);

        assertFalse(assurance.consumedAssurance(RECEIPT));
        assertEq(
            uint8(assurance.preparedAssurance(OPERATION).state),
            uint8(SourceBoundProRataEntitlementAssuranceV1.State.Prepared)
        );
        assertEq(uint8(prepared.state(OPERATION)), uint8(SourceBoundProRataControllerV2.State.Prepared));
        assertEq(
            uint8(ratification.state(OPERATION)),
            uint8(SourceBoundProRataEntitlementRatificationControllerV1.State.Prepared)
        );
        assertEq(uint8(allocator.entitlementOperation(OPERATION).state), uint8(IShortfallAllocatorV2.State.None));
        assertEq(token.balanceOf(address(reserve)), 101);
        assertEq(token.balanceOf(address(allocator)), 0);
        assertEq(reserve.totalReserved(), 0);
    }

    function test_OnlyBoundExecutionCallerCanReplaceStaleAssurance() public {
        assurance.prepareSourceAssurance(OPERATION, RECEIPT, _publicValues());
        ratification.registerPrepared(OPERATION);
        token.mint(address(this), 1);
        token.approve(address(reserve), 1);
        reserve.deposit(1);
        bytes32 current = reserve.economicState(preparedRoot).commitment;
        (bytes32 receipt, bytes memory values) = _replacementProof(current, 91);

        bytes32 oldAssurance = assurance.assuranceCommitment(OPERATION);
        bytes32 nextAssurance = assurance.assuranceCommitmentFor(OPERATION, receipt, keccak256(values), 2);
        vm.prank(address(0xBAD));
        vm.expectRevert(
            abi.encodeWithSelector(
                SourceBoundProRataEntitlementRatificationControllerV1.OnlyExecutionCaller.selector, address(0xBAD)
            )
        );
        ratification.replaceStaleAssurance(OPERATION, oldAssurance, nextAssurance, 1, receipt, values);
        assertEq(assurance.preparedAssurance(OPERATION).receiptId, RECEIPT);
    }

    function test_ReplacementRejectsCurrentAssuranceAndInvalidProofWithoutMutation() public {
        assurance.prepareSourceAssurance(OPERATION, RECEIPT, _publicValues());
        ratification.registerPrepared(OPERATION);
        bytes32 oldAssurance = assurance.assuranceCommitment(OPERATION);
        (bytes32 currentReceipt, bytes memory currentValues) = _replacementProof(reserveCommitment, 90);
        bytes32 currentReplacementCommitment =
            assurance.assuranceCommitmentFor(OPERATION, currentReceipt, keccak256(currentValues), 2);
        vm.expectRevert(SourceBoundProRataEntitlementAssuranceV1.AssuranceNotStale.selector);
        ratification.replaceStaleAssurance(
            OPERATION, oldAssurance, currentReplacementCommitment, 1, currentReceipt, currentValues
        );

        token.mint(address(this), 1);
        token.approve(address(reserve), 1);
        reserve.deposit(1);
        bytes32 live = reserve.economicState(preparedRoot).commitment;
        (bytes32 validReceipt, bytes memory validValues) = _replacementProof(live, 91);
        vm.expectRevert(SourceBoundProRataEntitlementAssuranceV1.AssuranceCommitmentMismatch.selector);
        ratification.replaceStaleAssurance(OPERATION, oldAssurance, bytes32(uint256(1)), 1, validReceipt, validValues);

        (bytes32 invalidReceipt, bytes memory invalidValues) = _replacementProof(live, 91);
        invalidValues[0] = bytes1(uint8(invalidValues[0]) ^ 1);
        bytes32 invalidReplacementCommitment =
            assurance.assuranceCommitmentFor(OPERATION, invalidReceipt, keccak256(invalidValues), 2);
        vm.expectRevert(SourceBoundProRataEntitlementAssuranceV1.InvalidIdentity.selector);
        ratification.replaceStaleAssurance(
            OPERATION, oldAssurance, invalidReplacementCommitment, 1, invalidReceipt, invalidValues
        );

        SourceBoundProRataEntitlementAssuranceV1.PreparedEntitlementAssurance memory stillOld =
            assurance.preparedAssurance(OPERATION);
        assertEq(stillOld.receiptId, RECEIPT);
        assertEq(stillOld.reserveStateCommitment, reserveCommitment);
        assertEq(stillOld.generation, 1);
        assertEq(assurance.assuranceCommitment(OPERATION), oldAssurance);
    }

    function test_DepositAndRepeatedReserveChangesAllowGenerationBoundRecovery() public {
        assurance.prepareSourceAssurance(OPERATION, RECEIPT, _publicValues());
        ratification.registerPrepared(OPERATION);

        uint64 revisionBeforeDeposit = reserve.availabilityRevision();
        token.mint(address(this), 1);
        token.approve(address(reserve), 1);
        reserve.deposit(1);
        bytes32 afterDeposit = reserve.economicState(preparedRoot).commitment;
        assertEq(reserve.availabilityRevision(), revisionBeforeDeposit, "deposit does not bump revision");
        assertTrue(afterDeposit != reserveCommitment, "full commitment includes changed balance");

        (bytes32 receipt1, bytes memory values1) = _replacementProof(afterDeposit, 91);
        bytes32 oldCommitment = assurance.assuranceCommitment(OPERATION);
        ratification.replaceStaleAssurance(
            OPERATION,
            oldCommitment,
            assurance.assuranceCommitmentFor(OPERATION, receipt1, keccak256(values1), 2),
            1,
            receipt1,
            values1
        );
        assertEq(assurance.preparedAssurance(OPERATION).generation, 2);

        reserve.reserveForOtherObligation(keccak256("recovery-reservation"), 1, block.timestamp + 1 days);
        bytes32 afterReservation = reserve.economicState(preparedRoot).commitment;
        (bytes32 receipt2, bytes memory values2) = _replacementProof(afterReservation, 90);
        bytes32 generation2Commitment = assurance.assuranceCommitment(OPERATION);
        ratification.replaceStaleAssurance(
            OPERATION,
            generation2Commitment,
            assurance.assuranceCommitmentFor(OPERATION, receipt2, keccak256(values2), 3),
            2,
            receipt2,
            values2
        );
        assertEq(assurance.preparedAssurance(OPERATION).generation, 3);

        bytes32 obsoleteReplacementCommitment =
            assurance.assuranceCommitmentFor(OPERATION, receipt2, keccak256(values2), 3);
        vm.expectRevert(SourceBoundProRataEntitlementAssuranceV1.GenerationMismatch.selector);
        ratification.replaceStaleAssurance(
            OPERATION, generation2Commitment, obsoleteReplacementCommitment, 2, receipt2, values2
        );

        ratification.ratifyAndFund(OPERATION, afterReservation, RESIDUAL);
        assertEq(token.balanceOf(address(allocator)), 90);
        assertEq(token.balanceOf(address(reserve)), 11);
        assertTrue(assurance.consumedAssurance(receipt2));
    }

    function test_ReplacementIsUnavailableAfterFundingOrConsumption() public {
        assurance.prepareSourceAssurance(OPERATION, RECEIPT, _publicValues());
        ratification.registerPrepared(OPERATION);
        ratification.ratifyAndFund(OPERATION, reserveCommitment, RESIDUAL);
        (bytes32 nextReceipt, bytes memory nextValues) = _replacementProof(reserveCommitment, 90);
        bytes32 nextCommitment = assurance.assuranceCommitmentFor(OPERATION, nextReceipt, keccak256(nextValues), 2);
        bytes32 currentAssuranceCommitment = assurance.assuranceCommitment(OPERATION);
        vm.expectRevert(
            abi.encodeWithSelector(
                SourceBoundProRataEntitlementRatificationControllerV1.InvalidState.selector,
                SourceBoundProRataEntitlementRatificationControllerV1.State.Funded
            )
        );
        ratification.replaceStaleAssurance(
            OPERATION, currentAssuranceCommitment, nextCommitment, 1, nextReceipt, nextValues
        );
    }

    function test_ActivationRequiresTheAdmittedLogicalRootCountAndTotal() public {
        assurance.prepareSourceAssurance(OPERATION, RECEIPT, _publicValues());
        ratification.registerPrepared(OPERATION);
        ratification.ratifyAndFund(OPERATION, reserveCommitment, RESIDUAL);

        bytes32[] memory wrongCommitments = new bytes32[](2);
        wrongCommitments[0] = keccak256("wrong-entitlement-0");
        wrongCommitments[1] = keccak256("wrong-entitlement-1");
        PublicPackedEntitlementRepresentationV1 wrong =
            new PublicPackedEntitlementRepresentationV1(wrongCommitments, 90);
        vm.expectRevert(ProductionProRataAllocatorV2.EntitlementRepresentationMismatch.selector);
        ratification.activateEntitlement(OPERATION, IEntitlementRepresentationV1(address(wrong)));

        IShortfallEntitlementAllocatorV1.EntitlementOperation memory stillFunded =
            allocator.entitlementOperation(OPERATION);
        assertEq(uint8(stillFunded.state), uint8(IShortfallAllocatorV2.State.Funded));
        assertEq(stillFunded.representation, address(0));
        assertEq(token.balanceOf(address(allocator)), 90);

        ratification.activateEntitlement(OPERATION, IEntitlementRepresentationV1(address(representation)));
        IShortfallEntitlementAllocatorV1.EntitlementOperation memory activated =
            allocator.entitlementOperation(OPERATION);
        assertEq(uint8(activated.state), uint8(IShortfallAllocatorV2.State.Activated));
        assertEq(activated.representation, address(representation));
        assertEq(activated.allocationClaimRoot, CLAIM);
        assertEq(
            uint8(ratification.state(OPERATION)),
            uint8(SourceBoundProRataEntitlementRatificationControllerV1.State.Activated)
        );
    }

    function test_ActivationAcceptsEquivalentCommittedImmutableRepresentation() public {
        assurance.prepareSourceAssurance(OPERATION, RECEIPT, _publicValues());
        ratification.registerPrepared(OPERATION);
        ratification.ratifyAndFund(OPERATION, reserveCommitment, RESIDUAL);

        bytes32[] memory commitments = new bytes32[](2);
        commitments[0] = keccak256("reference-entitlement-0");
        commitments[1] = keccak256("reference-entitlement-1");
        CommittedImmutableEntitlementRepresentationV1 productionTable =
            new CommittedImmutableEntitlementRepresentationV1(commitments, 90, 1);
        assertEq(productionTable.logicalRoot(), TABLE, "same B2 logical root");

        ratification.activateEntitlement(OPERATION, IEntitlementRepresentationV1(address(productionTable)));

        IShortfallEntitlementAllocatorV1.EntitlementOperation memory activated =
            allocator.entitlementOperation(OPERATION);
        assertEq(uint8(activated.state), uint8(IShortfallAllocatorV2.State.Activated));
        assertEq(activated.representation, address(productionTable));
        assertEq(activated.allocationClaimRoot, CLAIM);
        assertEq(allocator.outstandingLiability(OPERATION), 90);
    }

    function test_CancelAndRefundReturnsExactCapitalAndIsTerminal() public {
        assurance.prepareSourceAssurance(OPERATION, RECEIPT, _publicValues());
        ratification.registerPrepared(OPERATION);
        ratification.ratifyAndFund(OPERATION, reserveCommitment, RESIDUAL);

        uint64 revisionBeforeRefund = reserve.availabilityRevision();
        ratification.cancelAndRefundEntitlement(OPERATION);

        IShortfallEntitlementAllocatorV1.EntitlementOperation memory refunded =
            allocator.entitlementOperation(OPERATION);
        assertEq(uint8(refunded.state), uint8(IShortfallAllocatorV2.State.Cancelled));
        assertEq(allocator.fundingSource(OPERATION), address(reserve));
        assertEq(
            uint8(ratification.state(OPERATION)),
            uint8(SourceBoundProRataEntitlementRatificationControllerV1.State.CancelledRefunded)
        );
        assertEq(token.balanceOf(address(reserve)), 100, "exact refund to reserve");
        assertEq(token.balanceOf(address(allocator)), 0, "allocator custody fully returned");
        assertEq(token.allowance(address(reserve), address(allocator)), 0, "reserve allowance cleared");
        assertEq(reserve.totalReserved(), 0, "no reservation created by refund");
        assertEq(reserve.availabilityRevision(), revisionBeforeRefund + 1, "availability revision advances");
        OnchainShortfallReserveV2.EconomicState memory restored = reserve.economicState(preparedRoot);
        assertEq(restored.grossBalance, 100, "reserve gross restored");
        assertEq(restored.reservedBefore, 0, "reserved amount cleared");
        assertEq(restored.availableAmount, 90, "protected floor leaves original availability");

        vm.expectRevert(
            abi.encodeWithSelector(
                SourceBoundProRataEntitlementRatificationControllerV1.InvalidState.selector,
                SourceBoundProRataEntitlementRatificationControllerV1.State.CancelledRefunded
            )
        );
        ratification.activateEntitlement(OPERATION, IEntitlementRepresentationV1(address(representation)));
        vm.expectRevert(
            abi.encodeWithSelector(
                SourceBoundProRataEntitlementRatificationControllerV1.InvalidState.selector,
                SourceBoundProRataEntitlementRatificationControllerV1.State.CancelledRefunded
            )
        );
        ratification.cancelAndRefundEntitlement(OPERATION);
    }

    function test_ActivationWinsAgainstCancelAndRefund() public {
        assurance.prepareSourceAssurance(OPERATION, RECEIPT, _publicValues());
        ratification.registerPrepared(OPERATION);
        ratification.ratifyAndFund(OPERATION, reserveCommitment, RESIDUAL);
        ratification.activateEntitlement(OPERATION, IEntitlementRepresentationV1(address(representation)));

        vm.expectRevert(
            abi.encodeWithSelector(
                SourceBoundProRataEntitlementRatificationControllerV1.InvalidState.selector,
                SourceBoundProRataEntitlementRatificationControllerV1.State.Activated
            )
        );
        ratification.cancelAndRefundEntitlement(OPERATION);
        assertEq(token.balanceOf(address(reserve)), 10, "activated capital remains funded");
        assertEq(token.balanceOf(address(allocator)), 90, "activated allocator custody remains");
        assertEq(allocator.fundingSource(OPERATION), address(reserve));
    }

    function test_ActivationRejectsCountAndTotalMismatches() public {
        assurance.prepareSourceAssurance(OPERATION, RECEIPT, _publicValues());
        ratification.registerPrepared(OPERATION);
        ratification.ratifyAndFund(OPERATION, reserveCommitment, RESIDUAL);

        bytes32[] memory commitments = new bytes32[](1);
        commitments[0] = keccak256("different-count");
        PublicPackedEntitlementRepresentationV1 wrongCount =
            new PublicPackedEntitlementRepresentationV1(commitments, 90);
        vm.expectRevert(ProductionProRataAllocatorV2.EntitlementRepresentationMismatch.selector);
        ratification.activateEntitlement(OPERATION, IEntitlementRepresentationV1(address(wrongCount)));

        commitments = new bytes32[](2);
        commitments[0] = keccak256("reference-entitlement-0");
        commitments[1] = keccak256("reference-entitlement-1");
        PublicPackedEntitlementRepresentationV1 wrongTotal =
            new PublicPackedEntitlementRepresentationV1(commitments, 89);
        vm.expectRevert(ProductionProRataAllocatorV2.EntitlementRepresentationMismatch.selector);
        ratification.activateEntitlement(OPERATION, IEntitlementRepresentationV1(address(wrongTotal)));
        assertEq(uint8(allocator.entitlementOperation(OPERATION).state), uint8(IShortfallAllocatorV2.State.Funded));
    }

    function _prepareProofTuple() private {
        bytes memory values = _publicValues();
        IPrfStatementAdmission.AdmissionReceipt memory receipt;
        receipt.exists = true;
        receipt.configurationRoot = keccak256("successor-ratification-config");
        receipt.configurationEpoch = 7;
        receipt.verifierId = keccak256("successor-ratification-verifier");
        receipt.verifierAdapter = address(adapter);
        receipt.programVKey = adapter.programVKey();
        receipt.programElfSha256 = adapter.programElfSha256();
        receipt.statementSchemaVersionHash = adapter.statementSchemaVersion();
        receipt.publicValuesSchema = adapter.publicValuesSchema();
        receipt.statementRoot = ALLOCATION;
        receipt.publicValuesDigest = sha256(values);
        admission.setReceipt(RECEIPT, receipt);
    }

    function test_ExecutionChainMismatchRejectsBeforeAssuranceConsumption() public {
        assurance.prepareSourceAssurance(OPERATION, RECEIPT, _publicValues());
        ratification.registerPrepared(OPERATION);
        vm.chainId(block.chainid + 1);
        vm.expectRevert(SourceBoundProRataEntitlementRatificationControllerV1.PreparedContextMismatch.selector);
        ratification.ratifyAndFund(OPERATION, reserveCommitment, RESIDUAL);
        assertEq(
            uint8(ratification.state(OPERATION)),
            uint8(SourceBoundProRataEntitlementRatificationControllerV1.State.Prepared)
        );
        assertFalse(assurance.consumedAssurance(RECEIPT));
        assertEq(token.balanceOf(address(reserve)), 100);
        assertEq(token.balanceOf(address(allocator)), 0);
        assertEq(token.allowance(address(reserve), address(allocator)), 0);
    }

    function _publicValues() private view returns (bytes memory) {
        return abi.encode(
            adapter.PUBLIC_VALUES_SCHEMA(),
            preparedRoot,
            reserveCommitment,
            ALLOCATION,
            adapter.EXPECTED_DESCRIPTOR_ROOT(),
            TABLE,
            uint256(2),
            uint256(90),
            CLAIM
        );
    }

    function _replacementProof(bytes32 commitment, uint256 total)
        private
        returns (bytes32 receiptId, bytes memory values)
    {
        receiptId = keccak256(abi.encode("replacement", commitment, total));
        values = abi.encode(
            adapter.PUBLIC_VALUES_SCHEMA(),
            preparedRoot,
            commitment,
            ALLOCATION,
            adapter.EXPECTED_DESCRIPTOR_ROOT(),
            TABLE,
            uint256(2),
            total,
            CLAIM
        );
        IPrfStatementAdmission.AdmissionReceipt memory receipt;
        receipt.exists = true;
        receipt.configurationRoot = keccak256("successor-ratification-config");
        receipt.configurationEpoch = 7;
        receipt.verifierId = keccak256("successor-ratification-verifier");
        receipt.verifierAdapter = address(adapter);
        receipt.programVKey = adapter.programVKey();
        receipt.programElfSha256 = adapter.programElfSha256();
        receipt.statementSchemaVersionHash = adapter.statementSchemaVersion();
        receipt.publicValuesSchema = adapter.publicValuesSchema();
        receipt.statementRoot = ALLOCATION;
        receipt.publicValuesDigest = sha256(values);
        admission.setReceipt(receiptId, receipt);
    }

    function _preparedOperation()
        private
        view
        returns (SourceBoundEntitlementV1Commitments.PreparedOperation memory op)
    {
        op.operationId = OPERATION;
        op.initiator = address(this);
        op.chainId = uint64(block.chainid);
        op.reserve = address(reserve);
        op.token = address(token);
        op.allocator = address(allocator);
        op.configurationRoot = keccak256("successor-ratification-config");
        op.configurationEpoch = 7;
        op.sourceVerifierId = keccak256("successor-ratification-verifier");
        op.executionVerifierId = keccak256("successor-ratification-execution-verifier");
        op.sourceProgramVKey = adapter.programVKey();
        op.sourceProgramElfSha256 = adapter.programElfSha256();
        op.sourceStatementSchema = adapter.statementSchemaVersion();
        op.sourcePublicValuesSchema = adapter.publicValuesSchema();
        op.executionStatementSchema = keccak256("successor-ratification-execution-statement");
        op.executionPublicValuesSchema = keccak256("successor-ratification-execution-pv");
        op.policyRoot = keccak256("successor-ratification-policy");
        op.beneficiaryProfile = SourceBoundEntitlementV1Commitments.BeneficiaryProfile.SmartAccountV1;
        op.residualRecipient = RESIDUAL;
    }
}
