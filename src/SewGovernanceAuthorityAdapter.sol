// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {
    ISewGovernanceAuthority,
    ISewGovernanceAuthorityAdmin
} from "./interfaces/ISewGovernanceAuthority.sol";

/// @title SewGovernanceAuthorityAdapter
/// @notice Thin PRF compatibility layer controlled by the SEW Governor contract.
/// @dev
/// The adapter does NOT implement voting, quorum, timelock, or proposal execution.
/// Those remain authoritative in GovGovernor + TimelockController.
///
/// A SEW governance proposal should execute a GovGovernor `onlyGovernance` compatibility
/// function, which then calls this adapter as `governor`.
contract SewGovernanceAuthorityAdapter is ERC165, ISewGovernanceAuthorityAdmin {
    uint8 public constant TARGET_DIRECT = 0;
    uint8 public constant TARGET_SET = 1;

    bytes4 private constant ERC1271_INVALID = 0xffffffff;

    bytes32 public immutable override protocolGenesisRoot;
    address public immutable override governor;

    bytes32 public override authorityStateRoot;

    mapping(bytes32 decisionRoot => DecisionAuthorization) private _authorizations;

    event DecisionAuthorised(
        bytes32 indexed decisionRoot,
        uint8 indexed targetMode,
        bytes32 indexed targetRoot,
        bytes32 parentConfigurationRoot,
        bytes32 newConfigurationRoot,
        uint64 epoch
    );

    event DecisionRevoked(bytes32 indexed decisionRoot);

    event AuthorityStateRootUpdated(
        bytes32 indexed oldAuthorityStateRoot,
        bytes32 indexed newAuthorityStateRoot
    );

    error ZeroRoot();
    error ZeroAddress();
    error OnlyGovernor(address caller, address expectedGovernor);
    error InvalidTargetMode(uint8 targetMode);
    error DecisionAlreadyExists(bytes32 decisionRoot);
    error DecisionDoesNotExist(bytes32 decisionRoot);
    error DecisionAlreadyRevoked(bytes32 decisionRoot);
    error EpochMustBePositive();

    modifier onlyGovernor() {
        if (msg.sender != governor) revert OnlyGovernor(msg.sender, governor);
        _;
    }

    constructor(
        bytes32 protocolGenesisRoot_,
        address governor_,
        bytes32 initialAuthorityStateRoot_
    ) {
        if (
            protocolGenesisRoot_ == bytes32(0) ||
            initialAuthorityStateRoot_ == bytes32(0)
        ) revert ZeroRoot();
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
        uint64 epoch
    ) external override onlyGovernor {
        if (
            decisionRoot == bytes32(0) ||
            targetRoot == bytes32(0) ||
            parentConfigurationRoot == bytes32(0) ||
            newConfigurationRoot == bytes32(0)
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
            epoch
        );
    }

    /// @inheritdoc ISewGovernanceAuthorityAdmin
    function revokeDecision(bytes32 decisionRoot) external override onlyGovernor {
        DecisionAuthorization storage authorization = _authorizations[decisionRoot];
        if (!authorization.exists) revert DecisionDoesNotExist(decisionRoot);
        if (authorization.revoked) revert DecisionAlreadyRevoked(decisionRoot);

        authorization.revoked = true;
        emit DecisionRevoked(decisionRoot);
    }

    /// @inheritdoc ISewGovernanceAuthorityAdmin
    function updateAuthorityStateRoot(bytes32 newAuthorityStateRoot)
        external
        override
        onlyGovernor
    {
        if (newAuthorityStateRoot == bytes32(0)) revert ZeroRoot();

        bytes32 oldRoot = authorityStateRoot;
        authorityStateRoot = newAuthorityStateRoot;
        emit AuthorityStateRootUpdated(oldRoot, newAuthorityStateRoot);
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
        uint64 epoch
    ) public view override returns (bool) {
        DecisionAuthorization storage authorization = _authorizations[decisionRoot];

        return
            authorization.exists &&
            !authorization.revoked &&
            authorization.targetMode == targetMode &&
            authorization.targetRoot == targetRoot &&
            authorization.parentConfigurationRoot == parentConfigurationRoot &&
            authorization.newConfigurationRoot == newConfigurationRoot &&
            authorization.epoch == epoch;
    }

    /// @notice ERC-1271 compatibility for a governance-authorised canonical decision root.
    /// @dev
    /// `hash` is the PRF/SEW decision root.
    /// `signature` is an ABI-encoded authorization envelope:
    /// `(uint8 targetMode, bytes32 targetRoot, bytes32 parentConfigurationRoot,
    ///   bytes32 newConfigurationRoot, uint64 epoch)`.
    ///
    /// This intentionally represents contract/governance authority rather than an EOA signature.
    function isValidSignature(bytes32 hash, bytes calldata signature)
        external
        view
        override
        returns (bytes4)
    {
        // Five static ABI words.
        if (signature.length != 160) return ERC1271_INVALID;

        (
            uint8 targetMode,
            bytes32 targetRoot,
            bytes32 parentConfigurationRoot,
            bytes32 newConfigurationRoot,
            uint64 epoch
        ) = abi.decode(signature, (uint8, bytes32, bytes32, bytes32, uint64));

        return
            isAuthorisedDecision(
                hash,
                targetMode,
                targetRoot,
                parentConfigurationRoot,
                newConfigurationRoot,
                epoch
            )
                ? IERC1271.isValidSignature.selector
                : ERC1271_INVALID;
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC165, IERC165)
        returns (bool)
    {
        return
            interfaceId == type(ISewGovernanceAuthority).interfaceId ||
            interfaceId == type(ISewGovernanceAuthorityAdmin).interfaceId ||
            interfaceId == type(IERC1271).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
