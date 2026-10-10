// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Script} from "forge-std/Script.sol";
import {GateEEntitlementLocalOperator} from "./RunGateEEntitlementLocal.s.sol";
import {
    CommittedImmutableEntitlementRepresentationV1
} from "../src/applications/pro-rata/CommittedImmutableEntitlementRepresentationV1.sol";
import {ProductionProRataAllocatorV2} from "../src/applications/pro-rata/ProductionProRataAllocatorV2.sol";
import {IShortfallEntitlementAllocatorV1} from "../src/interfaces/IShortfallEntitlementAllocatorV1.sol";
import {IShortfallAllocatorV2} from "../src/interfaces/IShortfallAllocatorV2.sol";
import {IEntitlementRepresentationV1} from "../src/interfaces/IEntitlementRepresentationV1.sol";
import {
    SourceBoundProRataEntitlementRatificationControllerV1
} from "../src/applications/shortfall/SourceBoundProRataEntitlementRatificationControllerV1.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Activates the already-funded, deployment-derived vector-A local operation.
///         This fixture-specific tool does not calculate generic pro-rata allocation.
contract ActivateGateEEntitlementLocal is Script {
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
        IShortfallEntitlementAllocatorV1.EntitlementOperation memory funded =
            allocator.entitlementOperation(operationId);
        require(funded.state == IShortfallAllocatorV2.State.Funded, "operation must be Funded");
        require(
            funded.entitlementCount == 3 && funded.entitlementTotal == 70 && funded.amount == 70, "vector-A accounting"
        );
        require(allocator.outstandingLiability(operationId) == 0, "pre-activation liability");
        SourceBoundProRataEntitlementRatificationControllerV1 controller =
            SourceBoundProRataEntitlementRatificationControllerV1(
                vm.parseJsonAddress(manifest, ".contracts.ratificationController")
            );
        GateEEntitlementLocalOperator operator = GateEEntitlementLocalOperator(controller.executionCaller());
        uint256 key = vm.envUint("PRIVATE_KEY");
        require(
            operator.operator() == vm.addr(key) && operator.operationId() == operationId
                && address(operator.controller()) == address(controller),
            "bound operator"
        );
        bytes32[] memory commitments =
            vectorACommitments(witness, funded.allocationBindingRoot, operationId, funded.beneficiaryProfileWord);
        uint256 custodyBefore = IERC20(funded.token).balanceOf(address(allocator));
        vm.startBroadcast(key);
        CommittedImmutableEntitlementRepresentationV1 representation =
            new CommittedImmutableEntitlementRepresentationV1(commitments, funded.entitlementTotal, 2);
        require(representation.logicalRoot() == funded.evmEntitlementTableRoot, "admitted table root");
        require(
            representation.entitlementCount() == funded.entitlementCount
                && representation.entitlementTotal() == funded.entitlementTotal,
            "admitted count/total"
        );
        operator.activate(IEntitlementRepresentationV1(address(representation)));
        vm.stopBroadcast();
        IShortfallEntitlementAllocatorV1.EntitlementOperation memory activated =
            allocator.entitlementOperation(operationId);
        require(
            activated.state == IShortfallAllocatorV2.State.Activated
                && activated.representation == address(representation),
            "activation state"
        );
        require(allocator.outstandingLiability(operationId) == funded.entitlementTotal, "activated liability");
        require(activated.allocationClaimRoot == funded.allocationClaimRoot, "claim identity preserved");
        require(IERC20(funded.token).balanceOf(address(allocator)) == custodyBefore, "activation custody unchanged");
    }

    function vectorACommitments(string memory witness, bytes32 binding, bytes32 operationId, bytes32 profile)
        public
        pure
        returns (bytes32[] memory commitments)
    {
        string[3] memory claims = ["claim-a", "claim-b", "claim-c"];
        uint256[3] memory amounts = [uint256(35), uint256(21), uint256(14)];
        uint256[3] memory beneficiaryRows = [uint256(1), uint256(2), uint256(0)];
        uint256[3] memory openingRows = [uint256(2), uint256(0), uint256(1)];
        commitments = new bytes32[](3);
        for (uint256 i; i < claims.length; ++i) {
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
            bytes32 claimHash =
                keccak256(abi.encodePacked(bytes1(0x20), bytes1(uint8(bytes(claims[i]).length)), bytes(claims[i])));
            commitments[i] = keccak256(
                abi.encode(
                    keccak256("prf.source-bound-entitlement.commitment.v1"),
                    binding,
                    operationId,
                    i,
                    claimHash,
                    vm.parseJsonAddress(witness, string.concat(beneficiaryPath, ".beneficiary")),
                    amounts[i],
                    profile,
                    vm.parseJsonBytes32(witness, string.concat(openingPath, ".salt"))
                )
            );
        }
    }
}
