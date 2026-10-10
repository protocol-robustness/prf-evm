// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Script} from "forge-std/Script.sol";
import {PrfStatementAdmission} from "../src/core/PrfStatementAdmission.sol";
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
import {IEntitlementRepresentationV1} from "../src/interfaces/IEntitlementRepresentationV1.sol";
import {IShortfallEntitlementAllocatorV1} from "../src/interfaces/IShortfallEntitlementAllocatorV1.sol";
import {IShortfallAllocatorV2} from "../src/interfaces/IShortfallAllocatorV2.sol";
import {OnchainShortfallReserveV2} from "../src/applications/shortfall/OnchainShortfallReserveV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Local example authority, fixed to one operation and one operator.
///      Does not provide an arbitrary call or an administrator replacement route.
contract GateEEntitlementLocalOperator {
    address public immutable operator;
    bytes32 public immutable operationId;
    SourceBoundProRataEntitlementRatificationControllerV1 public immutable controller;

    constructor(
        address operator_,
        bytes32 operationId_,
        SourceBoundProRataEntitlementRatificationControllerV1 controller_
    ) {
        require(block.chainid == 31337, "local chain only");
        operator = operator_;
        operationId = operationId_;
        controller = controller_;
    }

    modifier onlyOperator() {
        require(msg.sender == operator, "only operation operator");
        _;
    }

    function fund(bytes32 commitment, address residualRecipient) external onlyOperator {
        controller.ratifyAndFund(operationId, commitment, residualRecipient);
    }

    function activate(IEntitlementRepresentationV1 representation) external onlyOperator {
        controller.activateEntitlement(operationId, representation);
    }

    function refund() external onlyOperator {
        controller.cancelAndRefundEntitlement(operationId);
    }
}

/// @notice Persists real proof admission and funding on the existing local deployment.
///         Activation and withdrawal are subsequent operator steps.
contract RunGateEEntitlementLocal is Script {
    function run() external {
        require(block.chainid == 31337, "local chain only");
        string memory manifest = vm.readFile(vm.envString("GATE_E_ENTITLEMENT_MANIFEST"));
        string memory fixture = vm.readFile(vm.envString("GATE_E_ENTITLEMENT_FIXTURE"));
        string memory witness = vm.readFile(vm.envString("GATE_E_ENTITLEMENT_INPUT"));
        require(
            keccak256(bytes(vm.parseJsonString(fixture, ".proof_system"))) == keccak256("groth16"), "Groth16 required"
        );
        require(
            keccak256(bytes(vm.parseJsonString(fixture, ".gate_e.manifest_digest")))
                == keccak256(bytes(vm.parseJsonString(manifest, ".manifestDigest"))),
            "manifest provenance"
        );
        require(sha256(bytes(witness)) == vm.parseJsonBytes32(fixture, ".source.witness_sha256"), "witness provenance");
        bytes32 operationId = vm.parseJsonBytes32(manifest, ".operationId");
        require(operationId == vm.parseJsonBytes32(fixture, ".gate_e.operation_id"), "operation provenance");
        PrfSourceBoundEntitlementVerifierAdapterV1 adapter =
            PrfSourceBoundEntitlementVerifierAdapterV1(vm.parseJsonAddress(manifest, ".contracts.sourceAdapter"));
        require(adapter.programVKey() == vm.parseJsonBytes32(fixture, ".vkey"), "VKey provenance");
        require(adapter.programElfSha256() == vm.parseJsonBytes32(fixture, ".elf_sha256"), "ELF provenance");
        bytes memory publicValues = vm.parseJsonBytes(fixture, ".public_values");
        PrfSourceBoundEntitlementVerifierAdapterV1.SourceBoundEntitlementPublicValuesV1 memory values =
            adapter.decodePublicValues(publicValues);
        SourceBoundProRataControllerV2 prepared =
            SourceBoundProRataControllerV2(vm.parseJsonAddress(manifest, ".contracts.preparedController"));
        require(prepared.preparedOperationRoot(operationId) == values.preparedOperationRoot, "prepared root");
        SourceBoundProRataEntitlementRatificationControllerV1 controller =
            SourceBoundProRataEntitlementRatificationControllerV1(
                vm.parseJsonAddress(manifest, ".contracts.ratificationController")
            );
        require(!controller.executionCallerBound(), "execution caller already bound; use recorded operator");
        uint256 key = vm.envUint("PRIVATE_KEY");
        require(vm.addr(key) == prepared.governance(), "bound governance required");
        OnchainShortfallReserveV2 reserve =
            OnchainShortfallReserveV2(vm.parseJsonAddress(manifest, ".contracts.reserve"));
        require(
            reserve.economicState(values.preparedOperationRoot).commitment == values.reserveStateCommitment,
            "stale reserve"
        );
        IERC20 token = IERC20(vm.parseJsonAddress(manifest, ".contracts.token"));
        address allocatorAddress = vm.parseJsonAddress(manifest, ".contracts.allocator");
        uint256 reserveBefore = token.balanceOf(address(reserve));
        uint256 allocatorBefore = token.balanceOf(allocatorAddress);
        vm.startBroadcast(key);
        GateEEntitlementLocalOperator operator =
            new GateEEntitlementLocalOperator(vm.addr(key), operationId, controller);
        controller.bindExecutionCaller(address(operator));
        bytes32 receipt = PrfStatementAdmission(vm.parseJsonAddress(manifest, ".contracts.admission"))
            .admitStatement(
                vm.parseJsonBytes32(manifest, ".localOnly.sourceVerifierId"),
                values.allocationBindingRoot,
                vm.parseJsonBytes(fixture, ".proof"),
                publicValues
            );
        SourceBoundProRataEntitlementAssuranceV1(vm.parseJsonAddress(manifest, ".contracts.assurance"))
            .prepareSourceAssurance(operationId, receipt, publicValues);
        controller.registerPrepared(operationId);
        operator.fund(values.reserveStateCommitment, vm.parseJsonAddress(manifest, ".localOnly.residualRecipient"));
        vm.stopBroadcast();
        require(reserveBefore - token.balanceOf(address(reserve)) == values.entitlementTotal, "reserve delta");
        require(token.balanceOf(allocatorAddress) - allocatorBefore == values.entitlementTotal, "allocator delta");
        IShortfallEntitlementAllocatorV1.EntitlementOperation memory funded =
            IShortfallEntitlementAllocatorV1(allocatorAddress).entitlementOperation(operationId);
        require(
            funded.state == IShortfallAllocatorV2.State.Funded && funded.amount == values.entitlementTotal,
            "funded state"
        );
        require(
            funded.evmEntitlementTableRoot == values.evmEntitlementTableRoot
                && funded.allocationClaimRoot == values.allocationClaimRoot,
            "funded roots"
        );
    }
}
