// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {GovernorVotes} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {ISewGovernanceAuthority, ISewGovernanceAuthorityAdmin} from "../interfaces/ISewGovernanceAuthority.sol";
import {ISewGovernanceProofModeAuthority} from "../interfaces/ISewGovernanceProofModeAuthority.sol";

/// @title GovGovernor
/// @notice OpenZeppelin Governor + TimelockControl for SEW Protocol DAO, with a thin PRF authority bridge.
/// @dev
/// PRF compatibility does not replace Governor proposal/voting/timelock semantics.
/// Adapter mutations are exposed through `onlyGovernance`, so they can only occur as part
/// of an executed Governor proposal even when the executor is an external TimelockController.
contract GovGovernor is Governor, GovernorSettings, GovernorCountingSimple, GovernorVotes, GovernorTimelockControl {
    uint256 public constant MAX_NON_CIRCULATING_ADDRESSES = 100;

    mapping(address => bool) public nonCirculatingAddresses;
    address[] public nonCirculatingAddressesList;

    uint256 public absoluteQuorum;

    /// @notice Chain-neutral PRF/SEW constitutional genesis root this Governor serves.
    bytes32 public immutable prfProtocolGenesisRoot;

    event NonCirculatingAddressAdded(address indexed addr);
    event NonCirculatingAddressRemoved(address indexed addr);
    event AbsoluteQuorumUpdated(uint256 oldQuorum, uint256 newQuorum);

    event PrfDecisionAuthorised(
        address indexed adapter,
        bytes32 indexed decisionRoot,
        uint8 targetMode,
        bytes32 indexed targetRoot,
        bytes32 parentConfigurationRoot,
        bytes32 newConfigurationRoot,
        bytes32 parentVerifierRegistryRoot,
        bytes32 newVerifierRegistryRoot,
        uint64 epoch
    );

    event PrfEntitlementProofModeAuthorized(address indexed adapter, bytes32 indexed decisionRoot, uint8 proofMode);

    event PrfDecisionRevoked(address indexed adapter, bytes32 indexed decisionRoot);

    event PrfAuthorityStateRootUpdated(address indexed adapter, bytes32 indexed newAuthorityStateRoot);

    error QuorumMustBePositive();
    error TooManyInitialAddresses(uint256 length, uint256 max);
    error ZeroAddress();
    error ZeroRoot();
    error DuplicateAddress(address addr);
    error MaxAddressesReached();
    error AddressNotInList(address addr);
    error PrfProtocolGenesisMismatch(bytes32 expected, bytes32 actual);

    constructor(
        address token,
        TimelockController timelock_,
        uint48 votingDelayBlocks,
        uint32 votingPeriodBlocks,
        uint256 proposalThresholdTokens,
        uint256 absoluteQuorumTokens,
        address[] memory initialNonCirculatingAddresses,
        bytes32 prfProtocolGenesisRoot_
    )
        Governor("Sew Protocol DAO")
        GovernorSettings(votingDelayBlocks, votingPeriodBlocks, proposalThresholdTokens)
        GovernorVotes(IVotes(token))
        GovernorTimelockControl(timelock_)
    {
        if (absoluteQuorumTokens == 0) revert QuorumMustBePositive();
        if (prfProtocolGenesisRoot_ == bytes32(0)) revert ZeroRoot();

        absoluteQuorum = absoluteQuorumTokens;
        prfProtocolGenesisRoot = prfProtocolGenesisRoot_;

        uint256 length = initialNonCirculatingAddresses.length;
        if (length > MAX_NON_CIRCULATING_ADDRESSES) {
            revert TooManyInitialAddresses(length, MAX_NON_CIRCULATING_ADDRESSES);
        }

        for (uint256 i = 0; i < length; i++) {
            address addr = initialNonCirculatingAddresses[i];
            if (addr == address(0)) revert ZeroAddress();
            if (nonCirculatingAddresses[addr]) revert DuplicateAddress(addr);

            nonCirculatingAddresses[addr] = true;
            nonCirculatingAddressesList.push(addr);
            emit NonCirculatingAddressAdded(addr);
        }
    }

    function votingDelay() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingDelay();
    }

    function votingPeriod() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingPeriod();
    }

    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.proposalThreshold();
    }

    /// @notice Absolute quorum amount in token units.
    function quorum(uint256 timepoint) public view override(Governor) returns (uint256) {
        timepoint;
        return absoluteQuorum;
    }

    /// @notice Reporting-only circulating-supply approximation retained from the existing SEW Governor.
    /// @dev Historical non-circulating values use past voting power because ERC20Votes does not expose
    ///      historical balances. This value is NOT used for quorum.
    function getCirculatingSupply(uint256 timepoint) public view returns (uint256) {
        IVotes votesToken = token();
        uint256 totalSupply;

        if (timepoint >= block.number) {
            totalSupply = IERC20(address(votesToken)).totalSupply();
            timepoint = block.number;
        } else {
            totalSupply = votesToken.getPastTotalSupply(timepoint);
        }

        uint256 nonCirculating;
        uint256 length = nonCirculatingAddressesList.length;

        for (uint256 i = 0; i < length; i++) {
            address addr = nonCirculatingAddressesList[i];
            if (!nonCirculatingAddresses[addr]) continue;

            if (timepoint == block.number) {
                nonCirculating += IERC20(address(votesToken)).balanceOf(addr);
            } else {
                nonCirculating += votesToken.getPastVotes(addr, timepoint);
            }
        }

        // Avoid wrapping a reporting-only helper if delegated voting power makes the
        // historical approximation exceed token supply.
        if (nonCirculating >= totalSupply) return 0;
        return totalSupply - nonCirculating;
    }

    function getCurrentCirculatingSupply() public view returns (uint256) {
        return getCirculatingSupply(block.number);
    }

    /// @dev Changed from a raw timelock-sender check to `onlyGovernance`.
    function addNonCirculatingAddress(address addr) external onlyGovernance {
        if (addr == address(0)) revert ZeroAddress();
        if (nonCirculatingAddresses[addr]) revert DuplicateAddress(addr);
        if (nonCirculatingAddressesList.length >= MAX_NON_CIRCULATING_ADDRESSES) {
            revert MaxAddressesReached();
        }

        nonCirculatingAddresses[addr] = true;
        nonCirculatingAddressesList.push(addr);
        emit NonCirculatingAddressAdded(addr);
    }

    /// @dev Changed from a raw timelock-sender check to `onlyGovernance`.
    function removeNonCirculatingAddress(address addr) external onlyGovernance {
        if (!nonCirculatingAddresses[addr]) revert AddressNotInList(addr);

        delete nonCirculatingAddresses[addr];

        uint256 length = nonCirculatingAddressesList.length;
        for (uint256 i = 0; i < length; i++) {
            if (nonCirculatingAddressesList[i] == addr) {
                nonCirculatingAddressesList[i] = nonCirculatingAddressesList[length - 1];
                nonCirculatingAddressesList.pop();
                break;
            }
        }

        emit NonCirculatingAddressRemoved(addr);
    }

    function getNonCirculatingAddressesCount() external view returns (uint256) {
        return nonCirculatingAddressesList.length;
    }

    /// @dev Changed from a raw timelock-sender check to `onlyGovernance`.
    function setAbsoluteQuorum(uint256 newQuorum) external onlyGovernance {
        if (newQuorum == 0) revert QuorumMustBePositive();

        uint256 oldQuorum = absoluteQuorum;
        absoluteQuorum = newQuorum;
        emit AbsoluteQuorumUpdated(oldQuorum, newQuorum);
    }

    // -------------------------------------------------------------------------
    // PRF / SEW governance compatibility surface
    // -------------------------------------------------------------------------

    /// @notice Register a canonical PRF/SEW decision as executable authority.
    /// @dev Must itself be called as a Governor proposal action.
    function authorisePrfDecision(
        address adapter,
        bytes32 decisionRoot,
        uint8 targetMode,
        bytes32 targetRoot,
        bytes32 parentConfigurationRoot,
        bytes32 newConfigurationRoot,
        bytes32 parentVerifierRegistryRoot,
        bytes32 newVerifierRegistryRoot,
        uint64 epoch
    ) external onlyGovernance {
        _requireProtocolCompatibleAdapter(adapter);

        ISewGovernanceAuthorityAdmin(adapter)
            .authoriseDecision(
                decisionRoot,
                targetMode,
                targetRoot,
                parentConfigurationRoot,
                newConfigurationRoot,
                parentVerifierRegistryRoot,
                newVerifierRegistryRoot,
                epoch
            );

        emit PrfDecisionAuthorised(
            adapter,
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

    /// @notice Authorizes a normal configuration decision and binds its live entitlement proof mode.
    /// @dev Both authorizations are recorded in this same Governor action; executor consumption is atomic.
    function authorisePrfDecisionWithEntitlementProofMode(
        address adapter,
        bytes32 decisionRoot,
        uint8 targetMode,
        bytes32 targetRoot,
        bytes32 parentConfigurationRoot,
        bytes32 newConfigurationRoot,
        bytes32 parentVerifierRegistryRoot,
        bytes32 newVerifierRegistryRoot,
        uint64 epoch,
        uint8 proofMode
    ) external onlyGovernance {
        _requireProtocolCompatibleAdapter(adapter);
        ISewGovernanceAuthorityAdmin(adapter)
            .authoriseDecision(
                decisionRoot,
                targetMode,
                targetRoot,
                parentConfigurationRoot,
                newConfigurationRoot,
                parentVerifierRegistryRoot,
                newVerifierRegistryRoot,
                epoch
            );
        ISewGovernanceProofModeAuthority(adapter).authoriseDecisionProofMode(decisionRoot, proofMode);
        emit PrfDecisionAuthorised(
            adapter,
            decisionRoot,
            targetMode,
            targetRoot,
            parentConfigurationRoot,
            newConfigurationRoot,
            parentVerifierRegistryRoot,
            newVerifierRegistryRoot,
            epoch
        );
        emit PrfEntitlementProofModeAuthorized(adapter, decisionRoot, proofMode);
    }

    /// @notice Revoke a previously registered decision before local consumption.
    function revokePrfDecision(address adapter, bytes32 decisionRoot) external onlyGovernance {
        _requireProtocolCompatibleAdapter(adapter);
        ISewGovernanceAuthorityAdmin(adapter).revokeDecision(decisionRoot);
        emit PrfDecisionRevoked(adapter, decisionRoot);
    }

    /// @notice Advance the separately committed SEW authority-state root.
    function updatePrfAuthorityStateRoot(address adapter, bytes32 newAuthorityStateRoot) external onlyGovernance {
        _requireProtocolCompatibleAdapter(adapter);
        ISewGovernanceAuthorityAdmin(adapter).updateAuthorityStateRoot(newAuthorityStateRoot);
        emit PrfAuthorityStateRootUpdated(adapter, newAuthorityStateRoot);
    }

    function _requireProtocolCompatibleAdapter(address adapter) private view {
        if (adapter == address(0)) revert ZeroAddress();

        bytes32 adapterProtocolRoot = ISewGovernanceAuthority(adapter).protocolGenesisRoot();

        if (adapterProtocolRoot != prfProtocolGenesisRoot) {
            revert PrfProtocolGenesisMismatch(prfProtocolGenesisRoot, adapterProtocolRoot);
        }
    }

    // -------------------------------------------------------------------------
    // OpenZeppelin multiple-inheritance overrides
    // -------------------------------------------------------------------------

    function state(uint256 proposalId) public view override(Governor, GovernorTimelockControl) returns (ProposalState) {
        return super.state(proposalId);
    }

    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public override(Governor) returns (uint256) {
        return super.propose(targets, values, calldatas, description);
    }

    function queue(address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash)
        public
        override
        returns (uint256)
    {
        return super.queue(targets, values, calldatas, descriptionHash);
    }

    function execute(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) public payable override returns (uint256) {
        return super.execute(targets, values, calldatas, descriptionHash);
    }

    function cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) public override(Governor) returns (uint256) {
        return super.cancel(targets, values, calldatas, descriptionHash);
    }

    /// @dev Fixes the supplied contract's `super.proposalNeedsQueuing(0)` bug.
    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor() internal view override(Governor, GovernorTimelockControl) returns (address) {
        return super._executor();
    }

    function supportsInterface(bytes4 interfaceId) public view override(Governor) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
