// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IShortfallAllocatorV2} from "../src/interfaces/IShortfallAllocatorV2.sol";
import {IPrfStatementAdmission} from "../src/interfaces/IPrfStatementAdmission.sol";
import {PrfStatementAdmission} from "../src/core/PrfStatementAdmission.sol";
import {OnchainShortfallReserveV2} from "../src/applications/shortfall/OnchainShortfallReserveV2.sol";
import {SourceBoundProRataControllerV2} from "../src/applications/shortfall/SourceBoundProRataControllerV2.sol";
import {SourceBoundProRataAssuranceV2} from "../src/applications/shortfall/SourceBoundProRataAssuranceV2.sol";
import {
    SourceBoundProRataRatificationControllerV2
} from "../src/applications/shortfall/SourceBoundProRataRatificationControllerV2.sol";
import {
    PrfSourceBoundStatementVerifierAdapterV2
} from "../src/verification/adapters/PrfSourceBoundStatementVerifierAdapterV2.sol";

/// @notice Gate E deployment-derived real-proof capital E2E.
///
/// Attaches to the deployment addresses in the live Gate E manifest and runs
/// the authentic closed-loop path
/// against the REAL SP1VerifierGroth16 (sp1-contracts v6.1.0 / SP1 6.3.1):
///
///   proof -> SP1VerifierGroth16 -> PrfStatementAdmission.admitStatement
///         -> SourceBoundProRataAssuranceV2.prepareSourceAssurance
///         -> SourceBoundProRataRatificationControllerV2.ratifyAndFund
///         -> OnchainShortfallReserveV2 -> ProductionProRataAllocatorV2
///
/// The proof fixture is the deployment-derived SP1 Groth16 fixture generated
/// against the source-bound-v2 program (VKey 0x0089abce... / ELF 0x1994d8...).
///
/// Canonical program identity (fixtures/source-bound-v2-identity.json):
///   SP1 release 6.3.1 / circuit v6.1.0 / Groth16
///   VKey   0x0089abceac18acb8d0686b81ea542b933339353807924bc021a9fe3820888127
///   ELF    0x1994d8b67004de3d5dfffc176434ae63f3d7ac32ae875d72093943ff8e82247b
contract GateEDeploymentDerivedRealProofTest is Test {
    uint256 internal constant INITIAL_CAPITAL = 100;
    uint256 internal constant PROTECTED_CAPITAL = 10;
    // --- Canonical source-bound V2 program identity ---
    bytes32 internal constant V2_VKEY = 0x0089abceac18acb8d0686b81ea542b933339353807924bc021a9fe3820888127;
    bytes32 internal constant V2_ELF_SHA256 = 0x1994d8b67004de3d5dfffc176434ae63f3d7ac32ae875d72093943ff8e82247b;

    // --- Genesis / configuration lineage (coherent Option A) ---
    bytes32 internal constant PROTOCOL_ROOT = 0x1111111111111111111111111111111111111111111111111111111111111111;
    bytes32 internal constant AUTHORITY_STATE_ROOT = 0x2222222222222222222222222222222222222222222222222222222222222222;
    bytes32 internal constant CHAIN_INSTANCE_ROOT = 0x5555555555555555555555555555555555555555555555555555555555555555;
    bytes32 internal CONFIG_ROOT_0;

    // --- LOCAL-ONLY prepared-operation inputs (documented operator choices,
    //      not deployment-committed) ---
    bytes32 internal OPERATION_ID;
    bytes32 internal SOURCE_VERIFIER_ID;
    bytes32 internal constant EXECUTION_VERIFIER_ID =
        0x0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c;
    bytes32 internal constant EXECUTION_STATEMENT_SCHEMA =
        0x0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d;
    bytes32 internal constant EXECUTION_PV_SCHEMA = 0x0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e;
    bytes32 internal constant POLICY_ROOT = 0x0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f;
    bytes32 internal ALLOCATION_BINDING_ROOT;
    bytes32 internal REALIZED_STATEMENT_ROOT;
    address internal RESIDUAL_RECIPIENT;
    uint64 internal CONFIGURATION_EPOCH;

    address internal deployer;
    IERC20 internal token;
    PrfStatementAdmission internal admission;
    PrfSourceBoundStatementVerifierAdapterV2 internal sourceAdapter;
    IShortfallAllocatorV2 internal allocator;
    OnchainShortfallReserveV2 internal reserve;
    SourceBoundProRataControllerV2 internal preparedController;
    SourceBoundProRataAssuranceV2 internal assurance;
    SourceBoundProRataRatificationControllerV2 internal ratification;
    bytes32 internal preparedRoot;
    bytes32 internal reserveCommitment;
    bytes internal publicValues;

    // ------------------------------------------------------------------
    function setUp() public {
        deployer = address(this);
        string memory manifestPath;
        try vm.envString("GATE_E_MANIFEST") returns (string memory configuredPath) {
            manifestPath = configuredPath;
        } catch {
            revert("Gate E integration requires GATE_E_MANIFEST and a live proof fixture");
        }
        string memory manifest = vm.readFile(manifestPath);
        assertEq(abi.decode(vm.parseJson(manifest, ".chainId"), (uint256)), block.chainid);

        token = IERC20(abi.decode(vm.parseJson(manifest, ".contracts.token"), (address)));
        reserve = OnchainShortfallReserveV2(abi.decode(vm.parseJson(manifest, ".contracts.reserve"), (address)));
        allocator = IShortfallAllocatorV2(abi.decode(vm.parseJson(manifest, ".contracts.allocator"), (address)));
        preparedController = SourceBoundProRataControllerV2(
            abi.decode(vm.parseJson(manifest, ".contracts.preparedController"), (address))
        );
        assurance = SourceBoundProRataAssuranceV2(abi.decode(vm.parseJson(manifest, ".contracts.assurance"), (address)));
        ratification = SourceBoundProRataRatificationControllerV2(
            abi.decode(vm.parseJson(manifest, ".contracts.ratificationController"), (address))
        );
        // This proof-only integration harness is the route for this isolated test;
        // production deployments bind the controller to their Assured Operations adapter.
        vm.prank(preparedController.governance());
        ratification.bindExecutionCaller(address(this));
        admission = PrfStatementAdmission(abi.decode(vm.parseJson(manifest, ".contracts.admission"), (address)));
        sourceAdapter = PrfSourceBoundStatementVerifierAdapterV2(
            abi.decode(vm.parseJson(manifest, ".contracts.sourceAdapter"), (address))
        );

        preparedRoot = abi.decode(vm.parseJson(manifest, ".preparedOperationRoot"), (bytes32));
        reserveCommitment = abi.decode(vm.parseJson(manifest, ".reserveStateCommitment"), (bytes32));
        OPERATION_ID = abi.decode(vm.parseJson(manifest, ".operationId"), (bytes32));
        ALLOCATION_BINDING_ROOT = abi.decode(vm.parseJson(manifest, ".allocationBindingRoot"), (bytes32));
        REALIZED_STATEMENT_ROOT = abi.decode(vm.parseJson(manifest, ".realizedStatementRoot"), (bytes32));
        CONFIG_ROOT_0 = abi.decode(vm.parseJson(manifest, ".configurationRoot"), (bytes32));
        CONFIGURATION_EPOCH = uint64(abi.decode(vm.parseJson(manifest, ".configurationEpoch"), (uint256)));
        SOURCE_VERIFIER_ID = abi.decode(vm.parseJson(manifest, ".localOnly.sourceVerifierId"), (bytes32));
        RESIDUAL_RECIPIENT = abi.decode(vm.parseJson(manifest, ".localOnly.residualRecipient"), (address));

        publicValues = abi.encode(
            sourceAdapter.PUBLIC_VALUES_DOMAIN(),
            preparedRoot,
            reserveCommitment,
            ALLOCATION_BINDING_ROOT,
            REALIZED_STATEMENT_ROOT,
            OPERATION_ID
        );
    }

    // ------------------------------------------------------------------
    // Positive: real deployment-derived proof admits and funds the topology.
    // ------------------------------------------------------------------
    function test_Positive_DeploymentDerivedProofAdmitsAndFunds() public {
        string memory fixturePath = _fixturePath();
        string memory fixtureJson = vm.readFile(fixturePath);
        bytes memory proof = abi.decode(vm.parseJson(fixtureJson, ".proof"), (bytes));
        bytes memory fixturePublicValues = abi.decode(vm.parseJson(fixtureJson, ".public_values"), (bytes));
        assertEq(abi.decode(vm.parseJson(fixtureJson, ".proof_system"), (string)), "groth16", "proof system");
        assertEq(
            abi.decode(vm.parseJson(fixtureJson, ".program_id"), (string)), "source-bound-v2-sp1-program.v2", "program"
        );
        assertEq(abi.decode(vm.parseJson(fixtureJson, ".vkey"), (bytes32)), V2_VKEY, "fixture VKey");
        assertEq(abi.decode(vm.parseJson(fixtureJson, ".elf_sha256"), (bytes32)), V2_ELF_SHA256, "fixture ELF");
        assertEq(
            abi.decode(vm.parseJson(fixtureJson, ".public_values_schema"), (string)),
            "prf/onchain-shortfall-allocation-binding-public-values.v2",
            "public values schema"
        );
        assertEq(fixturePublicValues, publicValues, "proof fixture must bind this deployment manifest");

        // 1. Real SP1 Groth16 admission.
        bytes32 receiptId = admission.admitStatement(SOURCE_VERIFIER_ID, ALLOCATION_BINDING_ROOT, proof, publicValues);
        assertTrue(receiptId != bytes32(0), "receipt id");
        IPrfStatementAdmission.AdmissionReceipt memory receipt = admission.admissionReceipt(receiptId);
        assertTrue(receipt.exists, "receipt exists");
        assertEq(receipt.verifierId, SOURCE_VERIFIER_ID, "verifier id");
        assertEq(receipt.verifierAdapter, address(sourceAdapter), "adapter");
        assertEq(receipt.programVKey, V2_VKEY, "vkey");
        assertEq(receipt.statementRoot, ALLOCATION_BINDING_ROOT, "statement root");
        assertEq(receipt.publicValuesDigest, sha256(publicValues), "pv digest");

        // 2. Freeze the prepared assurance from the admitted receipt.
        SourceBoundProRataAssuranceV2.PreparedSourceAssurance memory prepared =
            assurance.prepareSourceAssurance(OPERATION_ID, receiptId, publicValues);
        assertEq(prepared.preparedOperationRoot, preparedRoot, "prepared root");
        assertEq(prepared.reserveStateCommitment, reserveCommitment, "reserve commitment");
        assertEq(prepared.allocationBindingRoot, ALLOCATION_BINDING_ROOT, "allocation");
        assertEq(prepared.realizedStatementRoot, REALIZED_STATEMENT_ROOT, "realized");
        assertEq(uint8(prepared.state), uint8(SourceBoundProRataAssuranceV2.AssuranceState.Prepared), "prepared state");

        // 3. Ratify + fund through the reserve into the allocator.
        ratification.registerPrepared(OPERATION_ID);
        ratification.ratifyAndFund(
            OPERATION_ID, reserveCommitment, CONFIG_ROOT_0, CONFIGURATION_EPOCH, RESIDUAL_RECIPIENT
        );

        // Assertions: funded allocator operation, protected capital retained.
        IShortfallAllocatorV2.Operation memory op = allocator.operation(OPERATION_ID);
        assertEq(uint8(op.state), uint8(IShortfallAllocatorV2.State.Funded), "allocator funded");
        assertEq(op.amount, INITIAL_CAPITAL - PROTECTED_CAPITAL, "funded amount"); // 90
        assertEq(
            uint8(ratification.state(OPERATION_ID)),
            uint8(SourceBoundProRataRatificationControllerV2.State.Funded),
            "ratification funded"
        );
        assertTrue(assurance.consumedAssurance(receiptId), "assurance consumed");
        assertEq(token.balanceOf(address(reserve)), PROTECTED_CAPITAL, "protected retained");
        assertEq(token.balanceOf(address(allocator)), INITIAL_CAPITAL - PROTECTED_CAPITAL, "allocator balance");
    }

    // ------------------------------------------------------------------
    // Adversarial: wrong statement root is rejected by admission.
    // ------------------------------------------------------------------
    function test_WrongStatementRootRejected() public {
        bytes memory proof = abi.decode(vm.parseJson(vm.readFile(_fixturePath()), ".proof"), (bytes));
        bytes32 wrongRoot = bytes32(uint256(0xdead));
        vm.expectRevert();
        admission.admitStatement(SOURCE_VERIFIER_ID, wrongRoot, proof, publicValues);
    }

    // ------------------------------------------------------------------
    // Adversarial: wrong operation id in public values is rejected by assurance.
    // ------------------------------------------------------------------
    function test_WrongOperationIdRejectedAtAssurance() public {
        bytes memory proof = abi.decode(vm.parseJson(vm.readFile(_fixturePath()), ".proof"), (bytes));
        bytes32 receiptId = admission.admitStatement(SOURCE_VERIFIER_ID, ALLOCATION_BINDING_ROOT, proof, publicValues);

        bytes memory wrongPv = abi.encode(
            sourceAdapter.PUBLIC_VALUES_DOMAIN(),
            preparedRoot,
            reserveCommitment,
            ALLOCATION_BINDING_ROOT,
            REALIZED_STATEMENT_ROOT,
            bytes32(uint256(0xbeef))
        );
        vm.expectRevert();
        assurance.prepareSourceAssurance(OPERATION_ID, receiptId, wrongPv);
    }

    function _fixturePath() internal returns (string memory) {
        try vm.envString("GATE_E_FIXTURE") returns (string memory value) {
            return value;
        } catch {
            return "fixtures/gate-e-proof-fixture.json";
        }
    }
}
