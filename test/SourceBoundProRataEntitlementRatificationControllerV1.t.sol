// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPrfStatementAdmission} from "../src/interfaces/IPrfStatementAdmission.sol";
import {ISP1Verifier} from "../src/verification/interfaces/ISP1Verifier.sol";
import {IShortfallAllocatorV2} from "../src/interfaces/IShortfallAllocatorV2.sol";
import {ProductionProRataAllocatorV2} from "../src/applications/pro-rata/ProductionProRataAllocatorV2.sol";
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
        allocator = new ProductionProRataAllocatorV2(address(this));
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
