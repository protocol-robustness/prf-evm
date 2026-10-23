// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {SewGovernanceAuthorityAdapter} from "../src/integrations/sew/SewGovernanceAuthorityAdapter.sol";
import {PrfChainInstanceGenesis} from "../src/core/PrfChainInstanceGenesis.sol";
import {IPrfAuthorityTransitionAdmin} from "../src/interfaces/IPrfAuthorityTransitionAdmin.sol";
import {IPrfAuthorityTransitionValidator} from "../src/interfaces/IPrfAuthorityTransitionValidator.sol";

contract MockPrfAuthorityTransitionValidator is IPrfAuthorityTransitionValidator {
    bytes32 public immutable override localAuthorityPolicyRoot;

    constructor(bytes32 policyRoot_) {
        localAuthorityPolicyRoot = policyRoot_;
    }

    function isValidTransition(bytes32 executionCommitment, bytes calldata attestation)
        external
        view
        override
        returns (bool)
    {
        return attestation.length == 32 && abi.decode(attestation, (bytes32)) == executionCommitment;
    }
}

contract PrfAuthorityStateTransitionTest is Test {
    bytes32 private constant PROTOCOL_ROOT = keccak256("protocol");
    bytes32 private constant INITIAL_STATE_ROOT = keccak256("authority-state-initial");
    bytes32 private constant CONFIG_ROOT_0 = keccak256("configuration-0");
    bytes32 private constant CHAIN_ROOT = keccak256("chain-instance");
    bytes32 private constant POLICY_ROOT = keccak256("local-authority-policy");
    bytes32 private constant DECISION_PREIMAGES_ROOT = keccak256("decision-preimages");
    bytes32 private constant SUCCESSOR_STATE_ROOT = keccak256("authority-state-successor");
    bytes32 private constant TRANSITION_DOMAIN = keccak256("PRF_AUTHORITY_STATE_TRANSITION_EXECUTION_V1");

    SewGovernanceAuthorityAdapter private authority;
    PrfChainInstanceGenesis private genesis;
    MockPrfAuthorityTransitionValidator private validator;

    function setUp() public {
        authority = new SewGovernanceAuthorityAdapter(PROTOCOL_ROOT, address(this), INITIAL_STATE_ROOT);
        genesis = new PrfChainInstanceGenesis(
            PROTOCOL_ROOT,
            block.chainid,
            1,
            address(authority),
            INITIAL_STATE_ROOT,
            CONFIG_ROOT_0,
            address(this)
        );
        validator = new MockPrfAuthorityTransitionValidator(POLICY_ROOT);
        authority.enableAuthorityTransitions(genesis, POLICY_ROOT, validator);
        genesis.sealGenesis(CHAIN_ROOT, address(genesis).codehash, address(authority).codehash);
    }

    function _mutations() private pure returns (IPrfAuthorityTransitionAdmin.AuthorityMutation[] memory mutations) {
        mutations = new IPrfAuthorityTransitionAdmin.AuthorityMutation[](2);
        mutations[0] = IPrfAuthorityTransitionAdmin.AuthorityMutation({
            kind: 0,
            decisionRoot: bytes32(uint256(1)),
            targetMode: 0,
            targetRoot: CHAIN_ROOT,
            parentConfigurationRoot: CONFIG_ROOT_0,
            newConfigurationRoot: keccak256("configuration-1"),
            parentVerifierRegistryRoot: keccak256("registry-0"),
            newVerifierRegistryRoot: keccak256("registry-1"),
            epoch: 1,
            proofMode: 0
        });
        mutations[1] = IPrfAuthorityTransitionAdmin.AuthorityMutation({
            kind: 2,
            decisionRoot: bytes32(uint256(1)),
            targetMode: 0,
            targetRoot: bytes32(0),
            parentConfigurationRoot: bytes32(0),
            newConfigurationRoot: bytes32(0),
            parentVerifierRegistryRoot: bytes32(0),
            newVerifierRegistryRoot: bytes32(0),
            epoch: 0,
            proofMode: 1
        });
    }

    function _mutationRoot(IPrfAuthorityTransitionAdmin.AuthorityMutation[] memory mutations)
        private
        pure
        returns (bytes32 root)
    {
        root = keccak256("PRF_AUTHORITY_MUTATION_LIST_V1");
        for (uint256 i; i < mutations.length; ++i) {
            root = keccak256(abi.encode(root, keccak256(abi.encode(mutations[i]))));
        }
    }

    function _commitment(IPrfAuthorityTransitionAdmin.AuthorityMutation[] memory mutations)
        private
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(
            TRANSITION_DOMAIN,
            block.chainid,
            address(authority),
            CHAIN_ROOT,
            INITIAL_STATE_ROOT,
            SUCCESSOR_STATE_ROOT,
            POLICY_ROOT,
            uint64(0),
            uint64(1),
            _mutationRoot(mutations),
            DECISION_PREIMAGES_ROOT
        ));
    }

    function testValidatedTransitionAtomicallyAppliesMutationsAndSuccessorRoot() public {
        IPrfAuthorityTransitionAdmin.AuthorityMutation[] memory mutations = _mutations();
        bytes32 commitment = _commitment(mutations);
        bytes32 returned = authority.applyAuthorityStateTransition(
            INITIAL_STATE_ROOT,
            SUCCESSOR_STATE_ROOT,
            0,
            1,
            DECISION_PREIMAGES_ROOT,
            mutations,
            abi.encode(commitment)
        );

        assertEq(returned, commitment);
        assertEq(authority.authorityStateRoot(), SUCCESSOR_STATE_ROOT);
        assertEq(authority.authorityRevision(), 1);
        assertTrue(authority.isAuthorisedDecision(
            bytes32(uint256(1)),
            0,
            CHAIN_ROOT,
            CONFIG_ROOT_0,
            keccak256("configuration-1"),
            keccak256("registry-0"),
            keccak256("registry-1"),
            1
        ));
        assertTrue(authority.hasDecisionProofMode(bytes32(uint256(1))));
        assertTrue(authority.isAuthorisedDecisionProofMode(
            bytes32(uint256(1)),
            0,
            CHAIN_ROOT,
            CONFIG_ROOT_0,
            keccak256("configuration-1"),
            keccak256("registry-0"),
            keccak256("registry-1"),
            1,
            1
        ));
    }

    function testCrossLanguageExecutionCommitmentFixture() public view {
        IPrfAuthorityTransitionAdmin.AuthorityMutation[] memory mutations =
            new IPrfAuthorityTransitionAdmin.AuthorityMutation[](1);
        mutations[0] = IPrfAuthorityTransitionAdmin.AuthorityMutation({
            kind: 0,
            decisionRoot: bytes32(uint256(1)),
            targetMode: 0,
            targetRoot: bytes32(uint256(2)),
            parentConfigurationRoot: bytes32(uint256(3)),
            newConfigurationRoot: bytes32(uint256(4)),
            parentVerifierRegistryRoot: bytes32(uint256(5)),
            newVerifierRegistryRoot: bytes32(uint256(6)),
            epoch: 7,
            proofMode: 0
        });
        bytes32 mutationRoot = authority.authorityMutationRoot(mutations);
        assertEq(mutationRoot, 0xa76b0955b74068a7378c2bfedf83a3b1f2ea1709b2a7df3339dc32b64c8d8dba);
        bytes32 commitment = authority.authorityTransitionExecutionCommitment(
            address(0x1111111111111111111111111111111111111111),
            31337,
            bytes32(uint256(10)),
            bytes32(uint256(11)),
            bytes32(uint256(12)),
            bytes32(uint256(13)),
            0,
            1,
            mutationRoot,
            bytes32(uint256(14))
        );
        assertEq(commitment, 0x5ed3dd088226575602e112bf4cd71cce56bdaf266170c5f4bec1b478c38e1238);
    }

    function testLegacyAdministrativeMutationsAreDisabledAfterOptIn() public {
        vm.expectRevert(SewGovernanceAuthorityAdapter.LegacyMutationDisabled.selector);
        authority.updateAuthorityStateRoot(keccak256("arbitrary"));

        vm.expectRevert(SewGovernanceAuthorityAdapter.LegacyMutationDisabled.selector);
        authority.authoriseDecision(
            bytes32(uint256(2)), 0, CHAIN_ROOT, CONFIG_ROOT_0, keccak256("c1"),
            keccak256("r0"), keccak256("r1"), 1
        );

        assertEq(authority.authorityStateRoot(), INITIAL_STATE_ROOT);
        assertEq(authority.authorityRevision(), 0);
    }

    function testUnauthorizedCallerCannotApplyAuthorityTransition() public {
        IPrfAuthorityTransitionAdmin.AuthorityMutation[] memory mutations = _mutations();
        address unauthorized = address(0xBEEF);
        vm.expectRevert(abi.encodeWithSelector(
            SewGovernanceAuthorityAdapter.OnlyGovernor.selector, unauthorized, address(this)
        ));
        vm.prank(unauthorized);
        authority.applyAuthorityStateTransition(
            INITIAL_STATE_ROOT,
            SUCCESSOR_STATE_ROOT,
            0,
            1,
            DECISION_PREIMAGES_ROOT,
            mutations,
            abi.encode(_commitment(mutations))
        );
        assertEq(authority.authorityStateRoot(), INITIAL_STATE_ROOT);
        assertEq(authority.authorityRevision(), 0);
        assertFalse(authority.getDecisionAuthorization(bytes32(uint256(1))).exists);
    }

    function testInvalidAttestationLeavesAllAuthorityStateUnchanged() public {
        IPrfAuthorityTransitionAdmin.AuthorityMutation[] memory mutations = _mutations();
        vm.expectRevert(SewGovernanceAuthorityAdapter.InvalidAuthorityTransitionAttestation.selector);
        authority.applyAuthorityStateTransition(
            INITIAL_STATE_ROOT,
            SUCCESSOR_STATE_ROOT,
            0,
            1,
            DECISION_PREIMAGES_ROOT,
            mutations,
            abi.encode(bytes32(uint256(123)))
        );
        assertEq(authority.authorityStateRoot(), INITIAL_STATE_ROOT);
        assertEq(authority.authorityRevision(), 0);
        assertFalse(authority.getDecisionAuthorization(bytes32(uint256(1))).exists);
    }

    function testStalePredecessorAndSkippedRevisionReject() public {
        IPrfAuthorityTransitionAdmin.AuthorityMutation[] memory mutations = _mutations();
        bytes32 commitment = _commitment(mutations);
        vm.expectRevert(abi.encodeWithSelector(
            SewGovernanceAuthorityAdapter.AuthorityTransitionPredecessorMismatch.selector,
            INITIAL_STATE_ROOT,
            keccak256("stale")
        ));
        authority.applyAuthorityStateTransition(
            keccak256("stale"), SUCCESSOR_STATE_ROOT, 0, 1,
            DECISION_PREIMAGES_ROOT, mutations, abi.encode(commitment)
        );
        vm.expectRevert(abi.encodeWithSelector(
            SewGovernanceAuthorityAdapter.AuthorityTransitionRevisionMismatch.selector, 0, 0
        ));
        authority.applyAuthorityStateTransition(
            INITIAL_STATE_ROOT, SUCCESSOR_STATE_ROOT, 0, 2,
            DECISION_PREIMAGES_ROOT, mutations, abi.encode(commitment)
        );
        assertEq(authority.authorityStateRoot(), INITIAL_STATE_ROOT);
        assertEq(authority.authorityRevision(), 0);
    }

    function testUnorderedMutationListRejectsAtomically() public {
        IPrfAuthorityTransitionAdmin.AuthorityMutation[] memory mutations = _mutations();
        mutations[0].decisionRoot = bytes32(uint256(2));
        mutations[1].decisionRoot = bytes32(uint256(1));
        bytes32 commitment = _commitment(mutations);
        vm.expectRevert(SewGovernanceAuthorityAdapter.NonCanonicalAuthorityMutationOrder.selector);
        authority.applyAuthorityStateTransition(
            INITIAL_STATE_ROOT, SUCCESSOR_STATE_ROOT, 0, 1,
            DECISION_PREIMAGES_ROOT, mutations, abi.encode(commitment)
        );
        assertEq(authority.authorityStateRoot(), INITIAL_STATE_ROOT);
        assertEq(authority.authorityRevision(), 0);
    }

    function testTransitionOptInRejectsAdaptersWithLegacyMutationHistory() public {
        SewGovernanceAuthorityAdapter legacy = new SewGovernanceAuthorityAdapter(
            PROTOCOL_ROOT, address(this), INITIAL_STATE_ROOT
        );
        legacy.authoriseDecision(
            bytes32(uint256(99)), 0, CHAIN_ROOT, CONFIG_ROOT_0, keccak256("c1"),
            keccak256("r0"), keccak256("r1"), 1
        );
        PrfChainInstanceGenesis pending = new PrfChainInstanceGenesis(
            PROTOCOL_ROOT, block.chainid, 1, address(legacy), INITIAL_STATE_ROOT, CONFIG_ROOT_0, address(this)
        );
        MockPrfAuthorityTransitionValidator candidateValidator =
            new MockPrfAuthorityTransitionValidator(POLICY_ROOT);
        vm.expectRevert(SewGovernanceAuthorityAdapter.InvalidAuthorityTransitionBinding.selector);
        legacy.enableAuthorityTransitions(pending, POLICY_ROOT, candidateValidator);
        assertFalse(legacy.authorityTransitionsEnabled());
    }

    function testTransitionExecutionRequiresTheBoundGenesisToBeSealed() public {
        SewGovernanceAuthorityAdapter pendingAuthority = new SewGovernanceAuthorityAdapter(
            PROTOCOL_ROOT, address(this), INITIAL_STATE_ROOT
        );
        PrfChainInstanceGenesis pendingGenesis = new PrfChainInstanceGenesis(
            PROTOCOL_ROOT, block.chainid, 1, address(pendingAuthority),
            INITIAL_STATE_ROOT, CONFIG_ROOT_0, address(this)
        );
        MockPrfAuthorityTransitionValidator pendingValidator =
            new MockPrfAuthorityTransitionValidator(POLICY_ROOT);
        pendingAuthority.enableAuthorityTransitions(pendingGenesis, POLICY_ROOT, pendingValidator);
        vm.expectRevert(SewGovernanceAuthorityAdapter.AuthorityTransitionInstanceNotSealed.selector);
        pendingAuthority.applyAuthorityStateTransition(
            INITIAL_STATE_ROOT, SUCCESSOR_STATE_ROOT, 0, 1,
            DECISION_PREIMAGES_ROOT,
            new IPrfAuthorityTransitionAdmin.AuthorityMutation[](0),
            abi.encode(bytes32(uint256(1)))
        );
        assertEq(pendingAuthority.authorityStateRoot(), INITIAL_STATE_ROOT);
        assertEq(pendingAuthority.authorityRevision(), 0);
    }
}
