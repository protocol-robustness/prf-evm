// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPrfStatementAdmission} from "../src/interfaces/IPrfStatementAdmission.sol";
import {IShortfallAllocatorV2} from "../src/interfaces/IShortfallAllocatorV2.sol";
import {IShortfallEntitlementAllocatorV1} from "../src/interfaces/IShortfallEntitlementAllocatorV1.sol";
import {IEntitlementRepresentationV1} from "../src/interfaces/IEntitlementRepresentationV1.sol";
import {ISewGovernanceProofModeAuthority} from "../src/interfaces/ISewGovernanceProofModeAuthority.sol";
import {ProductionProRataAllocatorV2} from "../src/applications/pro-rata/ProductionProRataAllocatorV2.sol";
import {
    PublicPackedEntitlementRepresentationV1
} from "../src/applications/pro-rata/PublicPackedEntitlementRepresentationV1.sol";
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

    function test_DeploymentWitnessReconstructsProvedLogicalTable() public {
        string memory witness = vm.readFile(vm.envString("GATE_E_ENTITLEMENT_INPUT"));
        string memory fixture = vm.readFile(vm.envString("GATE_E_ENTITLEMENT_FIXTURE"));
        assertEq(abi.decode(vm.parseJson(fixture, ".gate_e.vector_id"), (string)), "A-minimum-realistic");
        assertEq(
            sha256(bytes(witness)),
            abi.decode(vm.parseJson(fixture, ".source.witness_sha256"), (bytes32)),
            "deployment witness provenance"
        );
        bytes memory publicValues = abi.decode(vm.parseJson(fixture, ".public_values"), (bytes));
        (
            bytes32 schema,
            bytes32 preparedRoot,
            bytes32 reserveCommitment,
            bytes32 allocationBindingRoot,
            bytes32 descriptorRoot,
            bytes32 tableRoot,
            uint256 count,
            uint256 total,
            bytes32 claimRoot
        ) = abi.decode(publicValues, (bytes32, bytes32, bytes32, bytes32, bytes32, bytes32, uint256, uint256, bytes32));
        assertEq(schema, keccak256("prf/source-bound-entitlement-public-values.v1"));
        assertEq(count, 3);
        assertEq(total, 70);
        bytes32 operationId = abi.decode(vm.parseJson(fixture, ".gate_e.operation_id"), (bytes32));
        bytes32[] memory commitments = _vectorACommitments(witness, allocationBindingRoot, operationId);
        PublicPackedEntitlementRepresentationV1 representation =
            new PublicPackedEntitlementRepresentationV1(commitments, total);
        assertEq(representation.logicalRoot(), tableRoot, "reconstructed logical table root");
        // These public roots are parsed to ensure the expected nine-word fixture is well-formed;
        // only the table root is an input to this representation reconstruction.
        assertTrue(preparedRoot != bytes32(0) && reserveCommitment != bytes32(0));
        assertTrue(descriptorRoot != bytes32(0) && claimRoot != bytes32(0));
    }

    function test_RealSuccessorProofAdmitsRatifiesFundsAndActivates() public {
        _runRealProofPath(1);
    }

    function test_RealSuccessorProofAdmitsRatifiesFundsAndRefunds() public {
        _runRealProofPath(0);
    }

    function test_RealSuccessorProofWithdrawsAcrossLiveRequestedRequiredModes() public {
        _runRealProofPath(2);
    }

    function _runRealProofPath(uint8 action) private {
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
        assertEq(
            address(
                ProductionProRataAllocatorV2(abi.decode(vm.parseJson(manifest, ".contracts.allocator"), (address)))
                    .proofModeSource()
            ),
            address(executor),
            "allocator reads live governed proof mode"
        );
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
        string memory witness = vm.readFile(vm.envString("GATE_E_ENTITLEMENT_INPUT"));
        bytes32 witnessHash = sha256(bytes(witness));
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

        if (action != 0) {
            bytes32[] memory commitments = _vectorACommitments(witness, values.allocationBindingRoot, operationId);
            PublicPackedEntitlementRepresentationV1 representation =
                new PublicPackedEntitlementRepresentationV1(commitments, values.entitlementTotal);
            assertEq(representation.logicalRoot(), values.evmEntitlementTableRoot, "fixture-derived logical table");
            ratification.activateEntitlement(operationId, IEntitlementRepresentationV1(address(representation)));
            IShortfallEntitlementAllocatorV1.EntitlementOperation memory activated =
                IShortfallEntitlementAllocatorV1(address(allocator)).entitlementOperation(operationId);
            assertEq(uint8(activated.state), uint8(IShortfallAllocatorV2.State.Activated), "allocator activated");
            assertEq(activated.representation, address(representation), "representation bound");
            assertEq(activated.allocationClaimRoot, values.allocationClaimRoot, "sole admitted claim root");
            assertEq(
                uint8(ratification.state(operationId)),
                uint8(SourceBoundProRataEntitlementRatificationControllerV1.State.Activated)
            );
            assertEq(
                IERC20(tokenAddress).balanceOf(address(allocator)),
                values.entitlementTotal,
                "activated liability custody"
            );
            if (action == 2) {
                ProductionProRataAllocatorV2 successorAllocator = ProductionProRataAllocatorV2(address(allocator));
                string[3] memory claims = ["claim-a", "claim-b", "claim-c"];
                uint256[3] memory amounts = [uint256(35), uint256(21), uint256(14)];
                address[3] memory beneficiaries = _vectorABeneficiaries(witness);
                bytes32[3] memory salts = _vectorASalts(witness);
                bytes32[] memory claimLeaves =
                    _vectorAClaimLeaves(values.allocationBindingRoot, operationId, claims, amounts, beneficiaries);

                // The operation is already activated. Each policy transition changes only
                // present-tense enforcement; roots and operation identity stay fixed.
                successorAllocator.withdraw(
                    operationId,
                    ProductionProRataAllocatorV2.EntitlementOpening(
                        0, bytes(claims[0]), beneficiaries[0], amounts[0], salts[0]
                    ),
                    _merkleSiblings(commitments, 0, keccak256("prf.source-bound-entitlement.table-node.v1")),
                    false,
                    new bytes32[](0),
                    ProductionProRataAllocatorV2.ProofMode.Requested
                );
                _applyGovernedProofMode(executor, 1, "gate-e-required-mode");
                successorAllocator.withdraw(
                    operationId,
                    ProductionProRataAllocatorV2.EntitlementOpening(
                        1, bytes(claims[1]), beneficiaries[1], amounts[1], salts[1]
                    ),
                    _merkleSiblings(commitments, 1, keccak256("prf.source-bound-entitlement.table-node.v1")),
                    true,
                    _merkleSiblings(claimLeaves, 1, keccak256("prf.source-bound-entitlement.claim-node.v1")),
                    ProductionProRataAllocatorV2.ProofMode.Requested
                );
                _applyGovernedProofMode(executor, 0, "gate-e-requested-mode");
                successorAllocator.withdraw(
                    operationId,
                    ProductionProRataAllocatorV2.EntitlementOpening(
                        2, bytes(claims[2]), beneficiaries[2], amounts[2], salts[2]
                    ),
                    _merkleSiblings(commitments, 2, keccak256("prf.source-bound-entitlement.table-node.v1")),
                    false,
                    new bytes32[](0),
                    ProductionProRataAllocatorV2.ProofMode.Requested
                );
                assertEq(successorAllocator.claimedAmount(operationId), values.entitlementTotal);
                assertEq(successorAllocator.claimedCount(operationId), values.entitlementCount);
                assertEq(successorAllocator.outstandingLiability(operationId), 0);
                assertEq(IERC20(tokenAddress).balanceOf(address(allocator)), 0, "all liabilities paid");
                assertEq(IERC20(tokenAddress).balanceOf(beneficiaries[0]), amounts[0]);
                assertEq(IERC20(tokenAddress).balanceOf(beneficiaries[1]), amounts[1]);
                assertEq(IERC20(tokenAddress).balanceOf(beneficiaries[2]), amounts[2]);
                assertEq(
                    uint8(successorAllocator.entitlementOperation(operationId).state),
                    uint8(IShortfallAllocatorV2.State.Closed)
                );
                assertEq(
                    values.allocationBindingRoot, funded.allocationBindingRoot, "mode changes do not alter identity"
                );
                assertEq(values.evmEntitlementTableRoot, funded.evmEntitlementTableRoot, "table identity stable");
                assertEq(values.allocationClaimRoot, funded.allocationClaimRoot, "claim identity stable");
            }
        } else {
            uint256 reserveBeforeRefund = IERC20(tokenAddress).balanceOf(address(reserve));
            uint256 allocatorBeforeRefund = IERC20(tokenAddress).balanceOf(address(allocator));
            ratification.cancelAndRefundEntitlement(operationId);
            IShortfallEntitlementAllocatorV1.EntitlementOperation memory refunded =
                IShortfallEntitlementAllocatorV1(address(allocator)).entitlementOperation(operationId);
            assertEq(uint8(refunded.state), uint8(IShortfallAllocatorV2.State.Cancelled), "allocator refund terminal");
            assertEq(
                IShortfallEntitlementAllocatorV1(address(allocator)).fundingSource(operationId),
                address(reserve),
                "recorded funding source"
            );
            assertEq(
                IERC20(tokenAddress).balanceOf(address(reserve)) - reserveBeforeRefund,
                values.entitlementTotal,
                "exact reserve refund"
            );
            assertEq(
                allocatorBeforeRefund - IERC20(tokenAddress).balanceOf(address(allocator)),
                values.entitlementTotal,
                "exact allocator debit"
            );
            assertEq(reserve.totalReserved(), 0, "refund does not create reservation");
            assertEq(
                uint8(ratification.state(operationId)),
                uint8(SourceBoundProRataEntitlementRatificationControllerV1.State.CancelledRefunded)
            );
        }
    }

    function _applyGovernedProofMode(SewConfigurationExecutor executor, uint8 mode, string memory label) private {
        ISewGovernanceProofModeAuthority authority = ISewGovernanceProofModeAuthority(address(executor.authority()));
        bytes32 parentConfiguration = executor.currentConfigurationRoot();
        bytes32 newConfiguration = keccak256(abi.encode(label, parentConfiguration));
        bytes32 registryRoot = executor.currentVerifierRegistryRoot();
        uint64 epoch = executor.currentEpoch() + 1;
        uint8 targetMode = 0;
        bytes32 targetRoot = executor.chainInstanceGenesisRoot();
        bytes32 decisionRoot =
            keccak256(abi.encode(label, parentConfiguration, newConfiguration, registryRoot, epoch, mode));
        address governor = authority.governor();
        vm.prank(governor);
        authority.authoriseDecision(
            decisionRoot,
            targetMode,
            targetRoot,
            parentConfiguration,
            newConfiguration,
            registryRoot,
            registryRoot,
            epoch
        );
        vm.prank(governor);
        authority.authoriseDecisionProofMode(decisionRoot, mode);
        executor.applyConfigurationWithEntitlementProofMode(
            decisionRoot, newConfiguration, registryRoot, epoch, targetMode, targetRoot, new bytes32[](0), mode
        );
    }

    function _vectorABeneficiaries(string memory witness) private pure returns (address[3] memory beneficiaries) {
        uint256[3] memory rows = [uint256(1), uint256(2), uint256(0)];
        for (uint256 i; i < rows.length; ++i) {
            beneficiaries[i] = abi.decode(
                vm.parseJson(witness, string.concat(".beneficiary-mapping[", vm.toString(rows[i]), "].beneficiary")),
                (address)
            );
        }
    }

    function _vectorASalts(string memory witness) private pure returns (bytes32[3] memory salts) {
        uint256[3] memory rows = [uint256(2), uint256(0), uint256(1)];
        for (uint256 i; i < rows.length; ++i) {
            salts[i] = abi.decode(
                vm.parseJson(witness, string.concat(".openings[", vm.toString(rows[i]), "].salt")), (bytes32)
            );
        }
    }

    function _vectorAClaimLeaves(
        bytes32 allocationBindingRoot,
        bytes32 operationId,
        string[3] memory claims,
        uint256[3] memory amounts,
        address[3] memory beneficiaries
    ) private pure returns (bytes32[] memory leaves) {
        leaves = new bytes32[](3);
        bytes32 domain = keccak256("prf.source-bound-entitlement.claim-leaf.v1");
        bytes32 profile = keccak256("smart-account-v1");
        for (uint256 i; i < leaves.length; ++i) {
            bytes memory claim = bytes(claims[i]);
            bytes32 claimHash = keccak256(abi.encodePacked(bytes1(0x20), bytes1(uint8(claim.length)), claim));
            leaves[i] = keccak256(
                abi.encode(
                    domain, allocationBindingRoot, operationId, i, claimHash, beneficiaries[i], amounts[i], profile
                )
            );
        }
    }

    function _merkleSiblings(bytes32[] memory leaves, uint256 index, bytes32 nodeDomain)
        private
        pure
        returns (bytes32[] memory siblings)
    {
        uint256 depth;
        for (uint256 width = leaves.length; width > 1; width = (width + 1) / 2) {
            ++depth;
        }
        siblings = new bytes32[](depth);
        uint256 cursor;
        while (leaves.length > 1) {
            uint256 siblingIndex = (index ^ 1);
            if (siblingIndex >= leaves.length) siblingIndex = index;
            siblings[cursor++] = leaves[siblingIndex];
            uint256 nextLength = (leaves.length + 1) / 2;
            bytes32[] memory next = new bytes32[](nextLength);
            for (uint256 i; i < leaves.length; i += 2) {
                bytes32 right = i + 1 < leaves.length ? leaves[i + 1] : leaves[i];
                next[i / 2] = keccak256(abi.encodePacked(nodeDomain, leaves[i], right));
            }
            leaves = next;
            index >>= 1;
        }
    }

    function _vectorACommitments(string memory witness, bytes32 allocationBindingRoot, bytes32 operationId)
        private
        pure
        returns (bytes32[] memory commitments)
    {
        // A-minimum-realistic is pinned by the fixture's source vector and witness hash above.
        // Its deterministic 70/100 Shortfall allocation is 35, 21, 14 in claim order.
        string[3] memory claims = ["claim-a", "claim-b", "claim-c"];
        uint256[3] memory amounts = [uint256(35), uint256(21), uint256(14)];
        uint256[3] memory beneficiaryRows = [uint256(1), uint256(2), uint256(0)];
        uint256[3] memory openingRows = [uint256(2), uint256(0), uint256(1)];
        commitments = new bytes32[](3);
        for (uint256 i; i < claims.length; ++i) {
            string memory claim = claims[i];
            string memory beneficiaryClaim = vm.parseJsonString(
                witness, string.concat(".beneficiary-mapping[", vm.toString(beneficiaryRows[i]), "].claim-id")
            );
            string memory openingClaim =
                vm.parseJsonString(witness, string.concat(".openings[", vm.toString(openingRows[i]), "].claim-id"));
            assertEq(beneficiaryClaim, claim, "beneficiary mapped by canonical claim");
            assertEq(openingClaim, claim, "salt mapped by canonical claim");
            address beneficiary = abi.decode(
                vm.parseJson(
                    witness, string.concat(".beneficiary-mapping[", vm.toString(beneficiaryRows[i]), "].beneficiary")
                ),
                (address)
            );
            bytes32 salt = abi.decode(
                vm.parseJson(witness, string.concat(".openings[", vm.toString(openingRows[i]), "].salt")), (bytes32)
            );
            bytes memory canonicalClaim =
                abi.encodePacked(bytes1(0x20), bytes1(uint8(bytes(claim).length)), bytes(claim));
            bytes32 claimHash = keccak256(canonicalClaim);
            commitments[i] = keccak256(
                abi.encode(
                    keccak256("prf.source-bound-entitlement.commitment.v1"),
                    allocationBindingRoot,
                    operationId,
                    i,
                    claimHash,
                    beneficiary,
                    amounts[i],
                    keccak256("smart-account-v1"),
                    salt
                )
            );
        }
    }

    function admissionStatementRoot(bytes memory publicValues) private pure returns (bytes32 root) {
        (,,, root,,,,,) =
            abi.decode(publicValues, (bytes32, bytes32, bytes32, bytes32, bytes32, bytes32, uint256, uint256, bytes32));
    }
}
