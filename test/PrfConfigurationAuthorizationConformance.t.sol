// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";

import {PrfChainInstanceGenesis} from "../src/PrfChainInstanceGenesis.sol";
import {SewGovernanceAuthorityAdapter} from "../src/SewGovernanceAuthorityAdapter.sol";
import {SewConfigurationExecutor} from "../src/SewConfigurationExecutor.sol";

/// @title PrfConfigurationAuthorizationConformanceTest
/// @notice Proves that the Clojure-derived chain-configuration-transition.v1
///         canonical root (decisionRoot) and its exact Solidity tuple field
///         are consumable by the SEW Governor + AuthorityAdapter + Executor
///         authorization and application surface.
///
///         The golden values are exported from the Clojure canonical layer:
///           etc/conformance/fixtures/solidity-authorization/
///         direct-transition-ethereum.json
contract PrfConfigurationAuthorizationConformanceTest is Test {
    // --- Exact golden values from Clojure fixture ---
    bytes32 internal constant PROTOCOL_ROOT =
        0xd77429dd50bd7fe18d5f41d55e53ccbd4c67d18c4f00b266f86dbaede01f9343;

    bytes32 internal constant AUTHORITY_STATE_ROOT =
        0x150c28318e27fffacd9233c7ace128f7639f16c47d1c844e5440a07db39867cd;

    bytes32 internal constant CHAIN_INSTANCE_ROOT =
        0xf6c0f226998ebecb1123f78c2b30347d24c6e7ca2131f44f880b8a43c052cf86;

    bytes32 internal constant CONFIG_PARENT_ROOT =
        0x12025a7e7948edfa9319ca31c2a8c81b57b8ad066c05aa2e79b5db9497e53035;

    bytes32 internal constant CONFIG_NEW_ROOT =
        0xeeabcdeca12cc86143032758cdf069751b47546dd69a94efeb008f4f2ae2b39c;

    bytes32 internal constant DECISION_ROOT =
        0x3f5f3d34df298102e72a3c016c66d74e2a6d00b0c5250db5c7691cf54b17ab46;

    uint8 internal constant TARGET_MODE_DIRECT = 0;
    uint8 internal constant TARGET_MODE_SET = 1;

    SewGovernanceAuthorityAdapter internal authority;
    PrfChainInstanceGenesis internal genesis;
    SewConfigurationExecutor internal executor;

    function setUp() public {
        // This test contract stands in for GovGovernor so adapter mutations can
        // exercise the same `only governor` boundary without constructing a token DAO.
        authority = new SewGovernanceAuthorityAdapter(
            PROTOCOL_ROOT,
            address(this),
            AUTHORITY_STATE_ROOT
        );

        genesis = new PrfChainInstanceGenesis(
            PROTOCOL_ROOT,
            block.chainid,
            1,
            address(authority),
            AUTHORITY_STATE_ROOT,
            CONFIG_PARENT_ROOT,
            address(this)
        );

        // Seal genesis with the exact chain-instance root from the Clojure fixture.
        // The runtime code hashes are the EVM-live codehashes of the contracts.
        genesis.sealGenesis(
            CHAIN_INSTANCE_ROOT,
            address(genesis).codehash,
            address(authority).codehash
        );

        executor = new SewConfigurationExecutor(genesis, authority);
    }

    function testDirectTransitionConformance() public {
        // 1. Current state: epoch 0, configuration = CONFIG_PARENT_ROOT
        assertEq(executor.currentEpoch(), 0);
        assertEq(executor.currentConfigurationRoot(), CONFIG_PARENT_ROOT);

        // 2. Authorise the exact Clojure-derived tuple.
        //    decisionRoot = chain-configuration-transition-root
        //    targetMode = 0 (direct)
        //    targetRoot = chain-instance-genesis-root (SHA-256, as bytes32)
        //    parentConfigurationRoot = CONFIG_PARENT_ROOT
        //    newConfigurationRoot = CONFIG_NEW_ROOT
        //    epoch = 1
        authority.authoriseDecision(
            DECISION_ROOT,
            TARGET_MODE_DIRECT,
            CHAIN_INSTANCE_ROOT,
            CONFIG_PARENT_ROOT,
            CONFIG_NEW_ROOT,
            1
        );

        // 3. Apply the transition.
        executor.applyConfiguration(
            DECISION_ROOT,
            CONFIG_NEW_ROOT,
            1,
            TARGET_MODE_DIRECT,
            CHAIN_INSTANCE_ROOT,
            new bytes32[](0)
        );

        // 4. Verify state transition.
        assertEq(executor.currentConfigurationRoot(), CONFIG_NEW_ROOT);
        assertEq(executor.currentEpoch(), 1);
        assertTrue(executor.consumedDecisionRoots(DECISION_ROOT));
    }

    function testMismatchNewRootFails() public {
        // Authorise the canonical tuple first (valid).
        authority.authoriseDecision(
            DECISION_ROOT,
            TARGET_MODE_DIRECT,
            CHAIN_INSTANCE_ROOT,
            CONFIG_PARENT_ROOT,
            CONFIG_NEW_ROOT,
            1
        );

        // Attempt to apply with a DIFFERENT new root but the same decisionRoot.
        // This must fail because the adapter binds decisionRoot to the exact tuple.
        bytes32 wrongNewRoot = keccak256(abi.encodePacked("wrong-new-root"));

        vm.expectRevert(abi.encodeWithSelector(
            SewConfigurationExecutor.DecisionNotAuthorised.selector,
            DECISION_ROOT
        ));
        executor.applyConfiguration(
            DECISION_ROOT,
            wrongNewRoot,
            1,
            TARGET_MODE_DIRECT,
            CHAIN_INSTANCE_ROOT,
            new bytes32[](0)
        );
    }

    function testMismatchTargetRootFails() public {
        // Authorise with the canonical targetRoot.
        authority.authoriseDecision(
            DECISION_ROOT,
            TARGET_MODE_DIRECT,
            CHAIN_INSTANCE_ROOT,
            CONFIG_PARENT_ROOT,
            CONFIG_NEW_ROOT,
            1
        );

        // Attempt to apply with a wrong targetRoot but the same decisionRoot.
        bytes32 wrongTargetRoot = keccak256(abi.encodePacked("wrong-target"));

        vm.expectRevert(abi.encodeWithSelector(
            SewConfigurationExecutor.DirectTargetMismatch.selector,
            CHAIN_INSTANCE_ROOT,
            wrongTargetRoot
        ));
        executor.applyConfiguration(
            DECISION_ROOT,
            CONFIG_NEW_ROOT,
            1,
            TARGET_MODE_DIRECT,
            wrongTargetRoot,
            new bytes32[](0)
        );
    }

    function testMismatchEpochFails() public {
        // Authorise with epoch 1.
        authority.authoriseDecision(
            DECISION_ROOT,
            TARGET_MODE_DIRECT,
            CHAIN_INSTANCE_ROOT,
            CONFIG_PARENT_ROOT,
            CONFIG_NEW_ROOT,
            1
        );

        // Apply with wrong epoch (2 instead of 1).
        vm.expectRevert(abi.encodeWithSelector(
            SewConfigurationExecutor.InvalidNextEpoch.selector,
            uint64(1),
            uint64(2)
        ));
        executor.applyConfiguration(
            DECISION_ROOT,
            CONFIG_NEW_ROOT,
            2,
            TARGET_MODE_DIRECT,
            CHAIN_INSTANCE_ROOT,
            new bytes32[](0)
        );
    }
}
