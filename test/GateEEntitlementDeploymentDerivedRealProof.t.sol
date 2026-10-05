// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPrfStatementAdmission} from "../src/interfaces/IPrfStatementAdmission.sol";
import {IShortfallAllocatorV2} from "../src/interfaces/IShortfallAllocatorV2.sol";
import {IShortfallEntitlementAllocatorV1} from "../src/interfaces/IShortfallEntitlementAllocatorV1.sol";
import {PrfStatementAdmission} from "../src/core/PrfStatementAdmission.sol";
import {PrfVerifierRegistry} from "../src/core/PrfVerifierRegistry.sol";
import {SewConfigurationExecutor} from "../src/integrations/sew/SewConfigurationExecutor.sol";
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

/// @notice Consumes a deployment-bound B3 Groth16 fixture on the same Anvil
///         instance, through successor admission, assurance, and funding.
contract GateEEntitlementDeploymentDerivedRealProofTest is Test {
    uint256 private constant EXPECTED_RESERVE_BALANCE = 10;

    function test_RealSuccessorProofAdmitsRatifiesAndFunds() public {
        string memory manifest = vm.readFile(vm.envString("GATE_E_ENTITLEMENT_MANIFEST"));
        assertEq(
            abi.decode(vm.parseJson(manifest, ".schema"), (string)),
            "prf-evm.gate-e-entitlement-deployment.v1",
            "manifest schema"
        );
        assertEq(abi.decode(vm.parseJson(manifest, ".chainId"), (uint256)), block.chainid, "chain id");

        address tokenAddress = abi.decode(vm.parseJson(manifest, ".contracts.token"), (address));
        OnchainShortfallReserveV2 reserve =
            OnchainShortfallReserveV2(abi.decode(vm.parseJson(manifest, ".contracts.reserve"), (address)));
        IShortfallAllocatorV2 allocator =
            IShortfallAllocatorV2(abi.decode(vm.parseJson(manifest, ".contracts.allocator"), (address)));
        SourceBoundProRataControllerV2 prepared = SourceBoundProRataControllerV2(
            abi.decode(vm.parseJson(manifest, ".contracts.preparedController"), (address))
        );
        SourceBoundProRataEntitlementAssuranceV1 assurance = SourceBoundProRataEntitlementAssuranceV1(
            abi.decode(vm.parseJson(manifest, ".contracts.assurance"), (address))
        );
        SourceBoundProRataEntitlementRatificationControllerV1 ratification =
            SourceBoundProRataEntitlementRatificationControllerV1(
                abi.decode(vm.parseJson(manifest, ".contracts.ratificationController"), (address))
            );
        PrfStatementAdmission admission =
            PrfStatementAdmission(abi.decode(vm.parseJson(manifest, ".contracts.admission"), (address)));
        PrfVerifierRegistry registry =
            PrfVerifierRegistry(abi.decode(vm.parseJson(manifest, ".contracts.registry"), (address)));
        SewConfigurationExecutor executor =
            SewConfigurationExecutor(abi.decode(vm.parseJson(manifest, ".contracts.executor"), (address)));
        PrfSourceBoundEntitlementVerifierAdapterV1 adapter = PrfSourceBoundEntitlementVerifierAdapterV1(
            abi.decode(vm.parseJson(manifest, ".contracts.sourceAdapter"), (address))
        );

        // This test harness is the local proof execution caller; deployments bind
        // this route to the production application dispatcher instead.
        vm.prank(prepared.governance());
        ratification.bindExecutionCaller(address(this));

        string memory fixture = vm.readFile(vm.envString("GATE_E_ENTITLEMENT_FIXTURE"));
        assertEq(abi.decode(vm.parseJson(fixture, ".proof_system"), (string)), "groth16", "proof type");
        assertEq(
            abi.decode(vm.parseJson(fixture, ".program_id"), (string)),
            "source-bound-entitlement-sp1-program.v1",
            "program id"
        );
        assertEq(
            abi.decode(vm.parseJson(fixture, ".public_values_schema"), (string)),
            "prf/source-bound-entitlement-public-values.v1",
            "public-values schema"
        );
        assertEq(abi.decode(vm.parseJson(fixture, ".public_values_length"), (uint256)), 288, "public-values length");
        assertEq(
            abi.decode(vm.parseJson(fixture, ".vkey"), (bytes32)),
            abi.decode(vm.parseJson(manifest, ".programVKey"), (bytes32)),
            "fixture VKey"
        );
        assertEq(
            abi.decode(vm.parseJson(fixture, ".elf_sha256"), (bytes32)),
            abi.decode(vm.parseJson(manifest, ".programElfSha256"), (bytes32)),
            "fixture ELF"
        );
        assertEq(
            abi.decode(vm.parseJson(fixture, ".gate_e.schema"), (string)),
            "prf-evm.gate-e-entitlement-proof-fixture.v1",
            "Gate E fixture schema"
        );
        assertEq(
            abi.decode(vm.parseJson(fixture, ".gate_e.manifest_digest"), (string)),
            abi.decode(vm.parseJson(manifest, ".manifestDigest"), (string)),
            "fixture manifest digest"
        );
        assertEq(
            abi.decode(vm.parseJson(fixture, ".gate_e.vector_id"), (string)), "A-minimum-realistic", "source vector"
        );

        bytes memory proof = abi.decode(vm.parseJson(fixture, ".proof"), (bytes));
        bytes memory publicValues = abi.decode(vm.parseJson(fixture, ".public_values"), (bytes));
        assertEq(publicValues.length, 288, "nine words");
        bytes32 witnessHash = sha256(bytes(vm.readFile(vm.envString("GATE_E_ENTITLEMENT_INPUT"))));
        assertEq(
            abi.decode(vm.parseJson(fixture, ".source.witness_sha256"), (bytes32)),
            witnessHash,
            "fixture witness provenance"
        );

        PrfSourceBoundEntitlementVerifierAdapterV1.SourceBoundEntitlementPublicValuesV1 memory values =
            adapter.decodePublicValues(publicValues);
        bytes32 preparedRoot = abi.decode(vm.parseJson(manifest, ".preparedOperationRoot"), (bytes32));
        bytes32 reserveCommitment = abi.decode(vm.parseJson(manifest, ".reserveStateCommitment"), (bytes32));
        bytes32 operationId = abi.decode(vm.parseJson(manifest, ".operationId"), (bytes32));
        assertEq(values.preparedOperationRoot, preparedRoot, "prepared root");
        assertEq(values.reserveStateCommitment, reserveCommitment, "reserve commitment");
        assertEq(values.allocationBindingRoot, admissionStatementRoot(publicValues), "binding root");
        assertEq(values.entitlementRepresentationDescriptorRoot, adapter.EXPECTED_DESCRIPTOR_ROOT(), "descriptor");
        assertEq(values.entitlementTotal, 70, "entitlement total equals live availability");
        assertEq(values.entitlementCount, 3, "entitlement count");
        assertEq(reserve.economicState(preparedRoot).commitment, reserveCommitment, "live reserve state");
        bytes32 registryRoot = executor.currentVerifierRegistryRoot();
        assertTrue(registry.isSealed(registryRoot), "sealed registry");
        assertEq(adapter.programVKey(), abi.decode(vm.parseJson(manifest, ".programVKey"), (bytes32)), "adapter VKey");
        assertEq(
            adapter.programElfSha256(),
            abi.decode(vm.parseJson(manifest, ".programElfSha256"), (bytes32)),
            "adapter ELF"
        );

        bytes32 verifierId = abi.decode(vm.parseJson(manifest, ".localOnly.sourceVerifierId"), (bytes32));
        bytes32 receiptId = admission.admitStatement(verifierId, values.allocationBindingRoot, proof, publicValues);
        IPrfStatementAdmission.AdmissionReceipt memory receipt = admission.admissionReceipt(receiptId);
        assertTrue(receipt.exists, "admission receipt");
        assertEq(receipt.verifierAdapter, address(adapter), "receipt adapter");
        assertEq(receipt.verifierRegistryRoot, registryRoot, "receipt registry root");
        assertEq(receipt.programVKey, adapter.programVKey(), "receipt VKey");
        assertEq(receipt.programElfSha256, adapter.programElfSha256(), "receipt ELF");
        assertEq(receipt.publicValuesDigest, sha256(publicValues), "receipt values digest");

        assurance.prepareSourceAssurance(operationId, receiptId, publicValues);
        ratification.registerPrepared(operationId);
        address residualRecipient = abi.decode(vm.parseJson(manifest, ".localOnly.residualRecipient"), (address));
        ratification.ratifyAndFund(operationId, reserveCommitment, residualRecipient);

        IShortfallEntitlementAllocatorV1.EntitlementOperation memory funded =
            IShortfallEntitlementAllocatorV1(address(allocator)).entitlementOperation(operationId);
        assertEq(uint8(funded.state), uint8(IShortfallAllocatorV2.State.Funded), "allocator funded");
        assertEq(funded.allocationBindingRoot, values.allocationBindingRoot, "allocation binding");
        assertEq(funded.descriptorRoot, values.entitlementRepresentationDescriptorRoot, "descriptor root");
        assertEq(funded.evmEntitlementTableRoot, values.evmEntitlementTableRoot, "table root");
        assertEq(funded.entitlementCount, values.entitlementCount, "count");
        assertEq(funded.entitlementTotal, values.entitlementTotal, "total");
        assertEq(funded.allocationClaimRoot, values.allocationClaimRoot, "claim root");
        assertEq(funded.amount, values.entitlementTotal, "funded amount");
        assertEq(IERC20(tokenAddress).balanceOf(address(reserve)), EXPECTED_RESERVE_BALANCE, "protected capital");
        assertEq(IERC20(tokenAddress).balanceOf(address(allocator)), values.entitlementTotal, "allocator custody");
        assertEq(reserve.totalReserved(), 0, "no stranded reservation");
        assertTrue(assurance.consumedAssurance(receiptId), "assurance consumed once");
        assertEq(uint8(prepared.state(operationId)), uint8(SourceBoundProRataControllerV2.State.Ratified));
    }

    function admissionStatementRoot(bytes memory publicValues) private pure returns (bytes32 root) {
        (,,, root,,,,,) =
            abi.decode(publicValues, (bytes32, bytes32, bytes32, bytes32, bytes32, bytes32, uint256, uint256, bytes32));
    }
}
