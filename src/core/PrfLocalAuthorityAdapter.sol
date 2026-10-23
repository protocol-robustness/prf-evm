// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ISewGovernanceAuthority, ISewGovernanceAuthorityAdmin} from "../interfaces/ISewGovernanceAuthority.sol";
import {ISewGovernanceProofModeAuthority} from "../interfaces/ISewGovernanceProofModeAuthority.sol";
import {IPrfAuthority} from "../interfaces/IPrfAuthority.sol";
import {IPrfAuthorityTransitionAdmin} from "../interfaces/IPrfAuthorityTransitionAdmin.sol";
import {IPrfAuthorityTransitionValidator} from "../interfaces/IPrfAuthorityTransitionValidator.sol";
import {IPrfChainInstanceGenesis} from "../interfaces/IPrfChainInstanceGenesis.sol";

/// @title PrfLocalAuthorityAdapter
/// @notice Local PRF authority adapter for synthetic and standalone PRF deployments.
/// @dev
/// The adapter does NOT implement voting, quorum, timelock, or proposal execution.
/// Those remain authoritative in the caller supplied as governor.
///
/// An authorized governance proposal should execute a GovGovernor `onlyGovernance` compatibility
/// function, which then calls this adapter as `governor`.
///
/// The DecisionAuthorization struct now binds parent/new verifier-registry roots
/// alongside the parent/new configuration roots, preventing a relayer from decoupling
/// configuration root C from verifier-registry root R.
contract PrfLocalAuthorityAdapter is ERC165, IPrfAuthority, ISewGovernanceProofModeAuthority, IPrfAuthorityTransitionAdmin {
    uint8 public constant TARGET_DIRECT = 0;
    uint8 public constant TARGET_SET = 1;

    bytes4 private constant ERC1271_INVALID = 0xffffffff;
    bytes32 private constant AUTHORITY_TRANSITION_DOMAIN = keccak256("PRF_AUTHORITY_STATE_TRANSITION_EXECUTION_V1");

    bytes32 public immutable override protocolGenesisRoot;
    address public immutable override governor;

    bytes32 public override authorityStateRoot;
    uint64 public authorityRevision;
    bytes32 public localAuthorityPolicyRoot;
    IPrfAuthorityTransitionValidator public authorityTransitionValidator;
    IPrfChainInstanceGenesis public authorityInstanceGenesis;
    bool public authorityTransitionsEnabled;
    bool public legacyAuthorityMutationOccurred;
    bool private _applyingAuthorityTransition;

    mapping(bytes32 decisionRoot => DecisionAuthorization) private _authorizations;
    mapping(bytes32 decisionRoot => uint8) private _proofModes;
    mapping(bytes32 decisionRoot => bool) private _hasProofMode;

    event DecisionAuthorised(
        bytes32 indexed decisionRoot,
        uint8 indexed targetMode,
        bytes32 indexed targetRoot,
        bytes32 parentConfigurationRoot,
        bytes32 newConfigurationRoot,
        bytes32 parentVerifierRegistryRoot,
        bytes32 newVerifierRegistryRoot,
        uint64 epoch
    );

    event DecisionRevoked(bytes32 indexed decisionRoot);

    event AuthorityStateRootUpdated(bytes32 indexed oldAuthorityStateRoot, bytes32 indexed newAuthorityStateRoot);
    event AuthorityTransitionsEnabled(address indexed genesis, bytes32 indexed policyRoot, address indexed validator);
    event AuthorityStateTransitionApplied(
        bytes32 indexed executionCommitment,
        bytes32 indexed previousRoot,
        bytes32 indexed successorRoot,
        uint64 previousRevision,
        uint64 successorRevision,
        bytes32 mutationRoot,
        bytes32 decisionPreimagesRoot
    );

    error ZeroRoot();
    error ZeroAddress();
    error OnlyGovernor(address caller, address expectedGovernor);
    error InvalidTargetMode(uint8 targetMode);
    error DecisionAlreadyExists(bytes32 decisionRoot);
    error DecisionDoesNotExist(bytes32 decisionRoot);
    error DecisionAlreadyRevoked(bytes32 decisionRoot);
    error EpochMustBePositive();
    error InvalidProofMode(uint8 proofMode);
    error LegacyMutationDisabled();
    error AuthorityTransitionAlreadyEnabled();
    error InvalidAuthorityTransitionBinding();
    error AuthorityTransitionInstanceNotSealed();
    error AuthorityTransitionPredecessorMismatch(bytes32 expected, bytes32 actual);
    error AuthorityTransitionRevisionMismatch(uint64 expected, uint64 actual);
    error AuthorityTransitionPolicyMismatch(bytes32 expected, bytes32 actual);
    error InvalidAuthorityTransitionAttestation();
    error NonCanonicalAuthorityMutationOrder();
    error InvalidAuthorityMutation(uint8 kind);

    modifier onlyGovernor() {
        if (msg.sender != governor && !(msg.sender == address(this) && _applyingAuthorityTransition)) {
            revert OnlyGovernor(msg.sender, governor);
        }
        _;
    }

    modifier legacyMutationAllowed() {
        if (authorityTransitionsEnabled && !_applyingAuthorityTransition) revert LegacyMutationDisabled();
        if (!authorityTransitionsEnabled && !_applyingAuthorityTransition) legacyAuthorityMutationOccurred = true;
        _;
    }

    constructor(bytes32 protocolGenesisRoot_, address governor_, bytes32 initialAuthorityStateRoot_) {
        if (protocolGenesisRoot_ == bytes32(0) || initialAuthorityStateRoot_ == bytes32(0)) revert ZeroRoot();
        if (governor_ == address(0)) revert ZeroAddress();

        protocolGenesisRoot = protocolGenesisRoot_;
        governor = governor_;
        authorityStateRoot = initialAuthorityStateRoot_;
    }

    /// @inheritdoc ISewGovernanceAuthorityAdmin
    function authoriseDecision(
        bytes32 decisionRoot,
        uint8 targetMode,
        bytes32 targetRoot,
        bytes32 parentConfigurationRoot,
        bytes32 newConfigurationRoot,
        bytes32 parentVerifierRegistryRoot,
        bytes32 newVerifierRegistryRoot,
        uint64 epoch
    ) external override onlyGovernor legacyMutationAllowed {
        if (
            decisionRoot == bytes32(0) || targetRoot == bytes32(0) || parentConfigurationRoot == bytes32(0)
                || newConfigurationRoot == bytes32(0) || parentVerifierRegistryRoot == bytes32(0)
                || newVerifierRegistryRoot == bytes32(0)
        ) revert ZeroRoot();
        if (targetMode > TARGET_SET) revert InvalidTargetMode(targetMode);
        if (epoch == 0) revert EpochMustBePositive();

        DecisionAuthorization storage existing = _authorizations[decisionRoot];
        if (existing.exists) revert DecisionAlreadyExists(decisionRoot);

        _authorizations[decisionRoot] = DecisionAuthorization({
            targetMode: targetMode,
            targetRoot: targetRoot,
            parentConfigurationRoot: parentConfigurationRoot,
            newConfigurationRoot: newConfigurationRoot,
            parentVerifierRegistryRoot: parentVerifierRegistryRoot,
            newVerifierRegistryRoot: newVerifierRegistryRoot,
            epoch: epoch,
            exists: true,
            revoked: false
        });

        emit DecisionAuthorised(
            decisionRoot,
            targetMode,
            targetRoot,
            parentConfigurationRoot,
            newConfigurationRoot,
            parentVerifierRegistryRoot,
            newVerifierRegistryRoot,
            epoch
        );
    }

    /// @inheritdoc ISewGovernanceProofModeAuthority
    function authoriseDecisionProofMode(bytes32 decisionRoot, uint8 proofMode) external override onlyGovernor legacyMutationAllowed {
        if (proofMode > 1) revert InvalidProofMode(proofMode);
        if (!_authorizations[decisionRoot].exists || _authorizations[decisionRoot].revoked) {
            revert DecisionDoesNotExist(decisionRoot);
        }
        if (_hasProofMode[decisionRoot]) revert DecisionAlreadyExists(decisionRoot);
        _hasProofMode[decisionRoot] = true;
        _proofModes[decisionRoot] = proofMode;
    }

    /// @inheritdoc ISewGovernanceProofModeAuthority
    function hasDecisionProofMode(bytes32 decisionRoot) external view override returns (bool) {
        return _hasProofMode[decisionRoot];
    }

    /// @inheritdoc ISewGovernanceProofModeAuthority
    function isAuthorisedDecisionProofMode(
        bytes32 decisionRoot,
        uint8 targetMode,
        bytes32 targetRoot,
        bytes32 parentConfigurationRoot,
        bytes32 newConfigurationRoot,
        bytes32 parentVerifierRegistryRoot,
        bytes32 newVerifierRegistryRoot,
        uint64 epoch,
        uint8 proofMode
    ) external view override returns (bool) {
        return _hasProofMode[decisionRoot] && _proofModes[decisionRoot] == proofMode
            && isAuthorisedDecision(
            decisionRoot,
            targetMode,
            targetRoot,
            parentConfigurationRoot,
            newConfigurationRoot,
            parentVerifierRegistryRoot,
            newVerifierRegistryRoot,
            epoch
        );
    }

    /// @inheritdoc ISewGovernanceAuthorityAdmin
    function revokeDecision(bytes32 decisionRoot) external override onlyGovernor legacyMutationAllowed {
        DecisionAuthorization storage authorization = _authorizations[decisionRoot];
        if (!authorization.exists) revert DecisionDoesNotExist(decisionRoot);
        if (authorization.revoked) revert DecisionAlreadyRevoked(decisionRoot);

        authorization.revoked = true;
        emit DecisionRevoked(decisionRoot);
    }

    /// @inheritdoc ISewGovernanceAuthorityAdmin
    function updateAuthorityStateRoot(bytes32 newAuthorityStateRoot) external override onlyGovernor legacyMutationAllowed {
        if (newAuthorityStateRoot == bytes32(0)) revert ZeroRoot();

        bytes32 oldRoot = authorityStateRoot;
        authorityStateRoot = newAuthorityStateRoot;
        emit AuthorityStateRootUpdated(oldRoot, newAuthorityStateRoot);
    }

    /// @notice Irreversibly enable policy-pinned, validated authority transitions.
    /// @dev Call before genesis sealing. It requires the adapter's exact initial
    ///      root and identity to match the pending genesis, then disables every
    ///      legacy standalone mutation route.
    function enableAuthorityTransitions(
        IPrfChainInstanceGenesis genesis_,
        bytes32 localAuthorityPolicyRoot_,
        IPrfAuthorityTransitionValidator validator_
    ) external override onlyGovernor {
        if (authorityTransitionsEnabled) revert AuthorityTransitionAlreadyEnabled();
        if (
            address(genesis_) == address(0) || address(validator_) == address(0)
                || address(validator_).code.length == 0 || localAuthorityPolicyRoot_ == bytes32(0)
                || genesis_.isSealedState() || legacyAuthorityMutationOccurred
                || genesis_.authorityAdapter() != address(this)
                || genesis_.protocolGenesisRoot() != protocolGenesisRoot
                || genesis_.initialAuthorityStateRoot() != authorityStateRoot
                || validator_.localAuthorityPolicyRoot() != localAuthorityPolicyRoot_
        ) revert InvalidAuthorityTransitionBinding();

        authorityInstanceGenesis = genesis_;
        localAuthorityPolicyRoot = localAuthorityPolicyRoot_;
        authorityTransitionValidator = validator_;
        authorityTransitionsEnabled = true;
        emit AuthorityTransitionsEnabled(address(genesis_), localAuthorityPolicyRoot_, address(validator_));
    }

    /// @notice Apply covered authority mutations and their successor root atomically.
    /// @dev The policy-pinned validator authenticates canonical state semantics,
    ///      capabilities and decision preimages. The adapter independently binds
    ///      the exact EVM mutation payload, instance, roots, policy and revisions.
    function applyAuthorityStateTransition(
        bytes32 expectedPreviousRoot,
        bytes32 successorRoot,
        uint64 previousRevision,
        uint64 successorRevision,
        bytes32 decisionPreimagesRoot,
        AuthorityMutation[] calldata mutations,
        bytes calldata attestation
    ) external override onlyGovernor returns (bytes32 executionCommitment) {
        if (_applyingAuthorityTransition) revert InvalidAuthorityTransitionBinding();
        if (!authorityTransitionsEnabled || !authorityInstanceGenesis.isSealedState()) {
            revert AuthorityTransitionInstanceNotSealed();
        }
        if (expectedPreviousRoot != authorityStateRoot) {
            revert AuthorityTransitionPredecessorMismatch(authorityStateRoot, expectedPreviousRoot);
        }
        if (successorRoot == bytes32(0) || decisionPreimagesRoot == bytes32(0)) revert ZeroRoot();
        if (previousRevision != authorityRevision || successorRevision != previousRevision + 1) {
            revert AuthorityTransitionRevisionMismatch(authorityRevision, previousRevision);
        }
        bytes32 currentPolicyRoot = authorityTransitionValidator.localAuthorityPolicyRoot();
        if (currentPolicyRoot != localAuthorityPolicyRoot) {
            revert AuthorityTransitionPolicyMismatch(localAuthorityPolicyRoot, currentPolicyRoot);
        }

        bytes32 mutationRoot = authorityMutationRoot(mutations);
        executionCommitment = authorityTransitionExecutionCommitment(
            address(this),
            block.chainid,
            authorityInstanceGenesis.chainInstanceGenesisRoot(),
            expectedPreviousRoot,
            successorRoot,
            localAuthorityPolicyRoot,
            previousRevision,
            successorRevision,
            mutationRoot,
            decisionPreimagesRoot
        );
        if (!authorityTransitionValidator.isValidTransition(executionCommitment, attestation)) {
            revert InvalidAuthorityTransitionAttestation();
        }

        _applyingAuthorityTransition = true;
        for (uint256 i; i < mutations.length; ++i) {
            AuthorityMutation calldata mutation = mutations[i];
            if (i != 0) {
                AuthorityMutation calldata previous = mutations[i - 1];
                if (
                    mutation.decisionRoot < previous.decisionRoot
                        || (mutation.decisionRoot == previous.decisionRoot && mutation.kind <= previous.kind)
                ) revert NonCanonicalAuthorityMutationOrder();
            }
            if (mutation.kind == 0) {
                if (mutation.proofMode != 0) revert InvalidAuthorityMutation(mutation.kind);
                this.authoriseDecision(
                    mutation.decisionRoot,
                    mutation.targetMode,
                    mutation.targetRoot,
                    mutation.parentConfigurationRoot,
                    mutation.newConfigurationRoot,
                    mutation.parentVerifierRegistryRoot,
                    mutation.newVerifierRegistryRoot,
                    mutation.epoch
                );
            } else if (mutation.kind == 1) {
                if (!_isZeroAuthoriseFields(mutation) || mutation.targetMode != 0 || mutation.proofMode != 0) {
                    revert InvalidAuthorityMutation(mutation.kind);
                }
                this.revokeDecision(mutation.decisionRoot);
            } else if (mutation.kind == 2) {
                if (!_isZeroAuthoriseFields(mutation) || mutation.targetMode != 0 || mutation.proofMode > 1) {
                    revert InvalidAuthorityMutation(mutation.kind);
                }
                this.authoriseDecisionProofMode(mutation.decisionRoot, mutation.proofMode);
            } else {
                revert InvalidAuthorityMutation(mutation.kind);
            }
        }
        _applyingAuthorityTransition = false;

        bytes32 oldRoot = authorityStateRoot;
        authorityStateRoot = successorRoot;
        authorityRevision = successorRevision;
        emit AuthorityStateRootUpdated(oldRoot, successorRoot);
        emit AuthorityStateTransitionApplied(
            executionCommitment,
            expectedPreviousRoot,
            successorRoot,
            previousRevision,
            successorRevision,
            mutationRoot,
            decisionPreimagesRoot
        );
    }

    function authorityTransitionExecutionCommitment(
        address adapter,
        uint256 chainId,
        bytes32 instanceRoot,
        bytes32 expectedPreviousRoot,
        bytes32 successorRoot,
        bytes32 policyRoot,
        uint64 previousRevision,
        uint64 successorRevision,
        bytes32 mutationRoot,
        bytes32 decisionPreimagesRoot
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(
            AUTHORITY_TRANSITION_DOMAIN,
            chainId,
            adapter,
            instanceRoot,
            expectedPreviousRoot,
            successorRoot,
            policyRoot,
            previousRevision,
            successorRevision,
            mutationRoot,
            decisionPreimagesRoot
        ));
    }

    function authorityMutationRoot(AuthorityMutation[] calldata mutations) public pure returns (bytes32 root) {
        root = keccak256("PRF_AUTHORITY_MUTATION_LIST_V1");
        for (uint256 i; i < mutations.length; ++i) {
            root = keccak256(abi.encode(root, keccak256(abi.encode(mutations[i]))));
        }
    }

    function _isZeroAuthoriseFields(AuthorityMutation calldata mutation) private pure returns (bool) {
        return mutation.targetRoot == bytes32(0) && mutation.parentConfigurationRoot == bytes32(0)
            && mutation.newConfigurationRoot == bytes32(0) && mutation.parentVerifierRegistryRoot == bytes32(0)
            && mutation.newVerifierRegistryRoot == bytes32(0) && mutation.epoch == 0;
    }

    /// @inheritdoc ISewGovernanceAuthority
    function getDecisionAuthorization(bytes32 decisionRoot)
        external
        view
        override
        returns (DecisionAuthorization memory)
    {
        return _authorizations[decisionRoot];
    }

    /// @inheritdoc ISewGovernanceAuthority
    function isAuthorisedDecision(
        bytes32 decisionRoot,
        uint8 targetMode,
        bytes32 targetRoot,
        bytes32 parentConfigurationRoot,
        bytes32 newConfigurationRoot,
        bytes32 parentVerifierRegistryRoot,
        bytes32 newVerifierRegistryRoot,
        uint64 epoch
    ) public view override returns (bool) {
        DecisionAuthorization storage authorization = _authorizations[decisionRoot];

        return authorization.exists && !authorization.revoked && authorization.targetMode == targetMode
            && authorization.targetRoot == targetRoot
            && authorization.parentConfigurationRoot == parentConfigurationRoot
            && authorization.newConfigurationRoot == newConfigurationRoot
            && authorization.parentVerifierRegistryRoot == parentVerifierRegistryRoot
            && authorization.newVerifierRegistryRoot == newVerifierRegistryRoot && authorization.epoch == epoch;
    }

    /// @notice ERC-1271 compatibility for a governance-authorised canonical decision root.
    /// @dev
    /// `hash` is the PRF/SEW decision root.
    /// `signature` is an ABI-encoded authorization envelope:
    /// `(uint8 targetMode, bytes32 targetRoot, bytes32 parentConfigurationRoot,
    ///   bytes32 newConfigurationRoot, bytes32 parentVerifierRegistryRoot,
    ///   bytes32 newVerifierRegistryRoot, uint64 epoch)`.
    ///
    /// This intentionally represents contract/governance authority rather than an EOA signature.
    function isValidSignature(bytes32 hash, bytes calldata signature) external view override returns (bytes4) {
        // Seven static ABI words = 7 * 32 = 224 bytes.
        if (signature.length != 224) return ERC1271_INVALID;

        (
            uint8 targetMode,
            bytes32 targetRoot,
            bytes32 parentConfigurationRoot,
            bytes32 newConfigurationRoot,
            bytes32 parentVerifierRegistryRoot,
            bytes32 newVerifierRegistryRoot,
            uint64 epoch
        ) = abi.decode(signature, (uint8, bytes32, bytes32, bytes32, bytes32, bytes32, uint64));

        return isAuthorisedDecision(
            hash,
            targetMode,
            targetRoot,
            parentConfigurationRoot,
            newConfigurationRoot,
            parentVerifierRegistryRoot,
            newVerifierRegistryRoot,
            epoch
        )
            ? IERC1271.isValidSignature.selector
            : ERC1271_INVALID;
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(ISewGovernanceAuthority).interfaceId
            || interfaceId == type(ISewGovernanceAuthorityAdmin).interfaceId
            || interfaceId == type(ISewGovernanceProofModeAuthority).interfaceId
            || interfaceId == type(IPrfAuthorityTransitionAdmin).interfaceId
            || interfaceId == type(IERC1271).interfaceId || super.supportsInterface(interfaceId);
    }
}
