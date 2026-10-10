// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Script} from "forge-std/Script.sol";
import {GateEEntitlementLocalOperator} from "./RunGateEEntitlementLocal.s.sol";
import {ProductionProRataAllocatorV2} from "../src/applications/pro-rata/ProductionProRataAllocatorV2.sol";
import {IShortfallEntitlementAllocatorV1} from "../src/interfaces/IShortfallEntitlementAllocatorV1.sol";
import {IShortfallAllocatorV2} from "../src/interfaces/IShortfallAllocatorV2.sol";
import {
    SourceBoundProRataEntitlementRatificationControllerV1
} from "../src/applications/shortfall/SourceBoundProRataEntitlementRatificationControllerV1.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Refunds one funded local operation to its already-recorded reserve.
contract RefundGateEEntitlementLocal is Script {
    function run() external {
        require(block.chainid == 31337, "local chain only");
        string memory manifest = vm.readFile(vm.envString("GATE_E_ENTITLEMENT_MANIFEST"));
        bytes32 operationId = vm.parseJsonBytes32(manifest, ".operationId");
        ProductionProRataAllocatorV2 allocator =
            ProductionProRataAllocatorV2(vm.parseJsonAddress(manifest, ".contracts.allocator"));
        SourceBoundProRataEntitlementRatificationControllerV1 controller =
            SourceBoundProRataEntitlementRatificationControllerV1(
                vm.parseJsonAddress(manifest, ".contracts.ratificationController")
            );
        address reserve = vm.parseJsonAddress(manifest, ".contracts.reserve");
        require(address(controller.reserve()) == reserve, "recorded reserve");
        IShortfallEntitlementAllocatorV1.EntitlementOperation memory funded =
            allocator.entitlementOperation(operationId);
        require(funded.state == IShortfallAllocatorV2.State.Funded, "refund requires Funded");
        require(address(funded.token) == vm.parseJsonAddress(manifest, ".contracts.token"), "recorded token");
        require(allocator.outstandingLiability(operationId) == 0, "no activated liabilities");
        GateEEntitlementLocalOperator operator = GateEEntitlementLocalOperator(controller.executionCaller());
        uint256 key = vm.envUint("PRIVATE_KEY");
        require(
            operator.operator() == vm.addr(key) && operator.operationId() == operationId
                && address(operator.controller()) == address(controller),
            "bound operator"
        );
        IERC20 token = IERC20(funded.token);
        uint256 reserveBefore = token.balanceOf(reserve);
        uint256 allocatorBefore = token.balanceOf(address(allocator));
        vm.startBroadcast(key);
        operator.refund();
        vm.stopBroadcast();
        require(token.balanceOf(reserve) - reserveBefore == funded.amount, "exact reserve refund");
        require(allocatorBefore - token.balanceOf(address(allocator)) == funded.amount, "exact allocator debit");
        require(
            allocator.entitlementOperation(operationId).state == IShortfallAllocatorV2.State.Cancelled,
            "terminal cancellation"
        );
        require(allocator.outstandingLiability(operationId) == 0, "zero remaining liability");
    }
}
