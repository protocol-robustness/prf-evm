// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Script} from "forge-std/Script.sol";
import {ProductionProRataAllocatorV2} from "../src/applications/pro-rata/ProductionProRataAllocatorV2.sol";
import {IShortfallEntitlementAllocatorV1} from "../src/interfaces/IShortfallEntitlementAllocatorV1.sol";
import {IShortfallAllocatorV2} from "../src/interfaces/IShortfallAllocatorV2.sol";
import {
    CommittedImmutableEntitlementRepresentationV1
} from "../src/applications/pro-rata/CommittedImmutableEntitlementRepresentationV1.sol";
import {SewConfigurationExecutor} from "../src/integrations/sew/SewConfigurationExecutor.sol";
import {ISewGovernanceProofModeAuthority} from "../src/interfaces/ISewGovernanceProofModeAuthority.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Fixture-specific local settlement through the existing live governed policy.
contract WithdrawGateEEntitlementLocal is Script {
    bytes32 private constant CLAIM_NODE = keccak256("prf.source-bound-entitlement.claim-node.v1");
    bytes32 private constant TABLE_NODE = keccak256("prf.source-bound-entitlement.table-node.v1");

    function run() external {
        require(block.chainid == 31337, "local chain only");
        string memory manifest = vm.readFile(vm.envString("GATE_E_ENTITLEMENT_MANIFEST"));
        string memory fixture = vm.readFile(vm.envString("GATE_E_ENTITLEMENT_FIXTURE"));
        string memory witness = vm.readFile(vm.envString("GATE_E_ENTITLEMENT_INPUT"));
        require(sha256(bytes(witness)) == vm.parseJsonBytes32(fixture, ".source.witness_sha256"), "witness provenance");
        require(
            keccak256(bytes(vm.parseJsonString(fixture, ".gate_e.manifest_digest")))
                == keccak256(bytes(vm.parseJsonString(manifest, ".manifestDigest"))),
            "manifest provenance"
        );
        require(
            keccak256(bytes(vm.parseJsonString(fixture, ".gate_e.vector_id"))) == keccak256("A-minimum-realistic"),
            "vector-A tool only"
        );
        bytes32 operationId = vm.parseJsonBytes32(manifest, ".operationId");
        require(operationId == vm.parseJsonBytes32(fixture, ".gate_e.operation_id"), "operation provenance");
        ProductionProRataAllocatorV2 allocator =
            ProductionProRataAllocatorV2(vm.parseJsonAddress(manifest, ".contracts.allocator"));
        IShortfallEntitlementAllocatorV1.EntitlementOperation memory current =
            allocator.entitlementOperation(operationId);
        require(
            current.state == IShortfallAllocatorV2.State.Activated && current.entitlementCount == 3
                && current.entitlementTotal == 70,
            "unclaimed activated vector-A operation"
        );
        require(
            allocator.claimedCount(operationId) == 0 && allocator.outstandingLiability(operationId) == 70,
            "initial liabilities"
        );
        SewConfigurationExecutor executor =
            SewConfigurationExecutor(vm.parseJsonAddress(manifest, ".contracts.executor"));
        require(
            address(allocator.proofModeSource()) == address(executor) && executor.currentEntitlementProofMode() == 0,
            "initial governed Requested mode"
        );
        uint256 key = vm.envUint("PRIVATE_KEY");
        require(
            ISewGovernanceProofModeAuthority(address(executor.authority())).governor() == vm.addr(key),
            "governor required for mode exercise"
        );
        ProductionProRataAllocatorV2.EntitlementOpening[3] memory openings = vectorAOpenings(witness);
        bytes32[] memory commitments = new bytes32[](3);
        bytes32[] memory leaves = new bytes32[](3);
        uint256[3] memory beforeBalances;
        for (uint256 i; i < 3; ++i) {
            commitments[i] = CommittedImmutableEntitlementRepresentationV1(current.representation).commitmentAt(i);
            bytes memory claim = openings[i].claimIdentityUtf8;
            bytes32 claimHash = keccak256(abi.encodePacked(bytes1(0x20), bytes1(uint8(claim.length)), claim));
            leaves[i] = keccak256(
                abi.encode(
                    keccak256("prf.source-bound-entitlement.claim-leaf.v1"),
                    current.allocationBindingRoot,
                    operationId,
                    i,
                    claimHash,
                    openings[i].beneficiary,
                    openings[i].amount,
                    current.beneficiaryProfileWord
                )
            );
            bytes32 commitment = keccak256(
                abi.encode(
                    keccak256("prf.source-bound-entitlement.commitment.v1"),
                    current.allocationBindingRoot,
                    operationId,
                    i,
                    claimHash,
                    openings[i].beneficiary,
                    openings[i].amount,
                    current.beneficiaryProfileWord,
                    openings[i].salt
                )
            );
            require(commitment == commitments[i], "opening equals immutable commitment");
            beforeBalances[i] = IERC20(current.token).balanceOf(openings[i].beneficiary);
        }
        require(treeRoot(leaves, CLAIM_NODE) == current.allocationClaimRoot, "admitted claim root");
        uint256 reserveBefore = IERC20(current.token).balanceOf(vm.parseJsonAddress(manifest, ".contracts.reserve"));
        vm.startBroadcast(key);
        allocator.withdraw(
            operationId,
            openings[0],
            siblings(commitments, 0, TABLE_NODE),
            false,
            new bytes32[](0),
            ProductionProRataAllocatorV2.ProofMode.Requested
        );
        applyMode(executor, 1, operationId, "local-required-withdrawal");
        allocator.withdraw(
            operationId,
            openings[1],
            siblings(commitments, 1, TABLE_NODE),
            true,
            siblings(leaves, 1, CLAIM_NODE),
            ProductionProRataAllocatorV2.ProofMode.Required
        );
        applyMode(executor, 0, operationId, "local-requested-withdrawal");
        // Supplied invalid optional allocation path must remain nonblocking in Requested.
        allocator.withdraw(
            operationId,
            openings[2],
            siblings(commitments, 2, TABLE_NODE),
            true,
            new bytes32[](0),
            ProductionProRataAllocatorV2.ProofMode.Requested
        );
        vm.stopBroadcast();
        require(
            allocator.claimedCount(operationId) == 3 && allocator.claimedAmount(operationId) == 70
                && allocator.outstandingLiability(operationId) == 0,
            "fully discharged"
        );
        require(allocator.entitlementOperation(operationId).state == IShortfallAllocatorV2.State.Closed, "closed");
        require(IERC20(current.token).balanceOf(address(allocator)) == 0, "allocator custody discharged");
        require(
            IERC20(current.token).balanceOf(vm.parseJsonAddress(manifest, ".contracts.reserve")) == reserveBefore,
            "reserve unchanged"
        );
        for (uint256 i; i < 3; ++i) {
            require(
                IERC20(current.token).balanceOf(openings[i].beneficiary) - beforeBalances[i] == openings[i].amount,
                "exact beneficiary payout"
            );
        }
    }

    function applyMode(SewConfigurationExecutor executor, uint8 mode, bytes32 operationId, string memory label)
        private
    {
        ISewGovernanceProofModeAuthority authority = ISewGovernanceProofModeAuthority(address(executor.authority()));
        bytes32 parent = executor.currentConfigurationRoot();
        bytes32 next = keccak256(abi.encode(label, operationId, parent));
        bytes32 registry = executor.currentVerifierRegistryRoot();
        uint64 epoch = executor.currentEpoch() + 1;
        bytes32 target = executor.chainInstanceGenesisRoot();
        bytes32 decision = keccak256(abi.encode(label, operationId, parent, next, registry, epoch, mode));
        authority.authoriseDecision(decision, 0, target, parent, next, registry, registry, epoch);
        authority.authoriseDecisionProofMode(decision, mode);
        executor.applyConfigurationWithEntitlementProofMode(
            decision, next, registry, epoch, 0, target, new bytes32[](0), mode
        );
    }

    function vectorAOpenings(string memory witness)
        public
        pure
        returns (ProductionProRataAllocatorV2.EntitlementOpening[3] memory openings)
    {
        string[3] memory claims = ["claim-a", "claim-b", "claim-c"];
        uint256[3] memory amounts = [uint256(35), uint256(21), uint256(14)];
        uint256[3] memory beneficiaryRows = [uint256(1), uint256(2), uint256(0)];
        uint256[3] memory openingRows = [uint256(2), uint256(0), uint256(1)];
        for (uint256 i; i < 3; ++i) {
            string memory beneficiaryPath = string.concat(".beneficiary-mapping[", vm.toString(beneficiaryRows[i]), "]");
            string memory openingPath = string.concat(".openings[", vm.toString(openingRows[i]), "]");
            require(
                keccak256(bytes(vm.parseJsonString(witness, string.concat(beneficiaryPath, ".claim-id"))))
                    == keccak256(bytes(claims[i])),
                "beneficiary claim mapping"
            );
            require(
                keccak256(bytes(vm.parseJsonString(witness, string.concat(openingPath, ".claim-id"))))
                    == keccak256(bytes(claims[i])),
                "salt claim mapping"
            );
            openings[i] = ProductionProRataAllocatorV2.EntitlementOpening(
                i,
                bytes(claims[i]),
                vm.parseJsonAddress(witness, string.concat(beneficiaryPath, ".beneficiary")),
                amounts[i],
                vm.parseJsonBytes32(witness, string.concat(openingPath, ".salt"))
            );
        }
    }

    function treeRoot(bytes32[] memory leaves, bytes32 domain) private pure returns (bytes32) {
        while (leaves.length > 1) leaves = nextLevel(leaves, domain);
        return leaves[0];
    }

    function nextLevel(bytes32[] memory leaves, bytes32 domain) private pure returns (bytes32[] memory next) {
        next = new bytes32[]((leaves.length + 1) / 2);
        for (uint256 i; i < leaves.length; i += 2) {
            next[i / 2] =
                keccak256(abi.encodePacked(domain, leaves[i], i + 1 < leaves.length ? leaves[i + 1] : leaves[i]));
        }
    }

    function siblings(bytes32[] memory leaves, uint256 index, bytes32 domain)
        private
        pure
        returns (bytes32[] memory path)
    {
        uint256 depth;
        for (uint256 width = leaves.length; width > 1; width = (width + 1) / 2) {
            ++depth;
        }
        path = new bytes32[](depth);
        uint256 cursor;
        while (leaves.length > 1) {
            uint256 sibling = index ^ 1;
            path[cursor++] = leaves[sibling < leaves.length ? sibling : index];
            leaves = nextLevel(leaves, domain);
            index >>= 1;
        }
    }
}
