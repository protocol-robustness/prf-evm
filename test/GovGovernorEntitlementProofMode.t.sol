// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {GovGovernor} from "../src/governance/GovGovernor.sol";
import {PrfChainInstanceGenesis} from "../src/core/PrfChainInstanceGenesis.sol";
import {PrfVerifierRegistry} from "../src/core/PrfVerifierRegistry.sol";
import {SewGovernanceAuthorityAdapter} from "../src/integrations/sew/SewGovernanceAuthorityAdapter.sol";
import {SewConfigurationExecutor} from "../src/integrations/sew/SewConfigurationExecutor.sol";

contract GovernorModeVoteToken is ERC20, ERC20Permit, ERC20Votes {
    constructor() ERC20("Governance Vote", "GOV") ERC20Permit("Governance Vote") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}

contract GovGovernorEntitlementProofModeTest is Test {
    bytes32 private constant PROTOCOL_ROOT = keccak256("governor-proof-mode-protocol");
    bytes32 private constant AUTHORITY_ROOT = keccak256("governor-proof-mode-authority");
    bytes32 private constant CONFIG_ROOT_0 = keccak256("governor-proof-mode-config-0");
    bytes32 private constant CHAIN_ROOT = keccak256("governor-proof-mode-chain-instance");
    bytes32 private initialRegistryRoot;
    bytes32 private constant VKEY = keccak256("governor-proof-mode-vkey");
    bytes32 private constant ELF = keccak256("governor-proof-mode-elf");
    bytes32 private constant SCHEMA = keccak256("governor-proof-mode-schema");
    bytes32 private constant PV_SCHEMA = keccak256("governor-proof-mode-public-values-schema");
    bytes32 private constant VERIFIER_ID = keccak256("governor-proof-mode-verifier");
    bytes32 private constant DECISION_ROOT = keccak256("governor-proof-mode-decision");
    bytes32 private constant CONFIG_ROOT_1 = keccak256("governor-proof-mode-config-1");

    GovernorModeVoteToken private voteToken;
    TimelockController private timelock;
    GovGovernor private governor;
    SewGovernanceAuthorityAdapter private authority;
    PrfChainInstanceGenesis private genesis;
    PrfVerifierRegistry private registry;
    SewConfigurationExecutor private executor;
    bytes32 private nextRegistryRoot;

    function setUp() public {
        voteToken = new GovernorModeVoteToken();
        address[] memory noProposers = new address[](0);
        address[] memory openExecutors = new address[](1);
        openExecutors[0] = address(0);
        timelock = new TimelockController(1, noProposers, openExecutors, address(this));
        address[] memory noExcluded = new address[](0);
        governor = new GovGovernor(address(voteToken), timelock, 1, 2, 1, 1, noExcluded, PROTOCOL_ROOT);
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        authority = new SewGovernanceAuthorityAdapter(PROTOCOL_ROOT, address(governor), AUTHORITY_ROOT);
        genesis = new PrfChainInstanceGenesis(
            PROTOCOL_ROOT, block.chainid, 1, address(authority), AUTHORITY_ROOT, CONFIG_ROOT_0, address(this)
        );
        genesis.sealGenesis(CHAIN_ROOT, address(genesis).codehash, address(authority).codehash);
        registry = new PrfVerifierRegistry(address(this));
        initialRegistryRoot = _emptyCanonicalRoot();
        registry.sealRegistry(initialRegistryRoot);
        executor = new SewConfigurationExecutor(genesis, authority, registry, initialRegistryRoot);
        nextRegistryRoot = _registerSuccessorVerifier();

        voteToken.mint(address(this), 100);
        voteToken.delegate(address(this));
        vm.roll(block.number + 1);
    }

    function test_ModeAuthorizationRunsOnlyThroughPassedGovernorTimelockProposal() public {
        bytes memory callData = abi.encodeCall(
            governor.authorisePrfDecisionWithEntitlementProofMode,
            (
                address(authority),
                DECISION_ROOT,
                uint8(0),
                CHAIN_ROOT,
                CONFIG_ROOT_0,
                CONFIG_ROOT_1,
                initialRegistryRoot,
                nextRegistryRoot,
                uint64(1),
                uint8(1)
            )
        );
        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = callData;
        string memory description = "Set PRF entitlement proof enforcement to Required";
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.roll(governor.proposalSnapshot(proposalId) + 1);
        governor.castVote(proposalId, 1);
        vm.roll(governor.proposalDeadline(proposalId) + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded));
        governor.queue(targets, values, calldatas, keccak256(bytes(description)));
        vm.warp(block.timestamp + 1);
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));

        assertTrue(authority.hasDecisionProofMode(DECISION_ROOT));
        assertTrue(
            authority.isAuthorisedDecisionProofMode(
                DECISION_ROOT, 0, CHAIN_ROOT, CONFIG_ROOT_0, CONFIG_ROOT_1, initialRegistryRoot, nextRegistryRoot, 1, 1
            )
        );
        assertEq(executor.currentEntitlementProofMode(), 0);
        executor.applyConfigurationWithEntitlementProofMode(
            DECISION_ROOT, CONFIG_ROOT_1, nextRegistryRoot, 1, 0, CHAIN_ROOT, new bytes32[](0), 1
        );
        assertEq(executor.currentEntitlementProofMode(), 1);
        assertEq(executor.currentConfigurationRoot(), CONFIG_ROOT_1);
    }

    function _emptyCanonicalRoot() private view returns (bytes32) {
        return registry.computeCanonicalRoot(
            new bytes32[](0),
            new address[](0),
            new bytes32[](0),
            new bytes32[](0),
            new string[](0),
            new bytes32[](0),
            new bytes32[](0),
            new bool[](0)
        );
    }

    function _registerSuccessorVerifier() private returns (bytes32 root) {
        bytes32[] memory ids = new bytes32[](1);
        address[] memory adapters = new address[](1);
        bytes32[] memory vkeys = new bytes32[](1);
        bytes32[] memory elfs = new bytes32[](1);
        string[] memory programIds = new string[](1);
        bytes32[] memory schemas = new bytes32[](1);
        bytes32[] memory pvSchemas = new bytes32[](1);
        bool[] memory actives = new bool[](1);
        ids[0] = VERIFIER_ID;
        adapters[0] = address(this);
        vkeys[0] = VKEY;
        elfs[0] = ELF;
        programIds[0] = "test-governed-proof-mode.v1";
        schemas[0] = SCHEMA;
        pvSchemas[0] = PV_SCHEMA;
        actives[0] = true;
        root = registry.computeCanonicalRoot(ids, adapters, vkeys, elfs, programIds, schemas, pvSchemas, actives);
        registry.registerVerifier(root, VERIFIER_ID, address(this), VKEY, ELF, programIds[0], SCHEMA, PV_SCHEMA);
        registry.sealRegistry(root);
    }
}
