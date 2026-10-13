// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IShortfallAllocatorV2} from "../../interfaces/IShortfallAllocatorV2.sol";
import {IShortfallEntitlementAllocatorV1} from "../../interfaces/IShortfallEntitlementAllocatorV1.sol";
import {IEntitlementRepresentationV1} from "../../interfaces/IEntitlementRepresentationV1.sol";
import {IEntitlementProofModeSource} from "../../interfaces/IEntitlementProofModeSource.sol";

/// @notice V2 custody successor used by atomic Shortfall ratification.
/// @dev Create/fund is atomic at the reserve boundary. Funded capital can be
/// returned before downstream reliance; allocation claims remain separate.
contract ProductionProRataAllocatorV2 is IShortfallAllocatorV2, IShortfallEntitlementAllocatorV1 {
    bytes32 private constant SMART_ACCOUNT_PROFILE = keccak256("smart-account-v1");
    bytes32 private constant IMMUTABLE_ADDRESS_PROFILE = keccak256("immutable-address-v1");
    bytes32 private constant COMMITMENT_DOMAIN = keccak256("prf.source-bound-entitlement.commitment.v1");
    bytes32 private constant TABLE_NODE_DOMAIN = keccak256("prf.source-bound-entitlement.table-node.v1");
    bytes32 private constant TABLE_ROOT_DOMAIN = keccak256("prf.source-bound-entitlement.table-root.v1");
    bytes32 private constant CLAIM_LEAF_DOMAIN = keccak256("prf.source-bound-entitlement.claim-leaf.v1");
    bytes32 private constant CLAIM_NODE_DOMAIN = keccak256("prf.source-bound-entitlement.claim-node.v1");
    enum ProofMode {
        Requested,
        Required
    }
    enum ProofObservation {
        NotProvided,
        Valid,
        Invalid
    }

    struct EntitlementOpening {
        uint256 index;
        bytes claimIdentityUtf8;
        address beneficiary;
        uint256 amount;
        bytes32 salt;
    }

    address public immutable operationAuthority;
    IEntitlementProofModeSource public immutable proofModeSource;
    address public override fundingAuthority;
    bool public override fundingAuthorityBound;
    mapping(bytes32 => Operation) private _operations;
    mapping(bytes32 => IShortfallEntitlementAllocatorV1.EntitlementOperation) private _entitlementOperations;
    mapping(bytes32 => address) public override(IShortfallAllocatorV2, IShortfallEntitlementAllocatorV1) fundingSource;
    bool private _entered;
    mapping(bytes32 operationId => mapping(uint256 wordIndex => uint256 bits)) private _consumedWords;
    mapping(bytes32 operationId => mapping(bytes32 claimIdentityHash => bool)) public consumedClaimIdentity;
    mapping(bytes32 operationId => uint256) public claimedAmount;
    mapping(bytes32 operationId => uint256) public claimedCount;
    mapping(bytes32 operationId => uint256) public override outstandingLiability;

    error OnlyOperationAuthority(address caller);
    error InvalidOperation();
    error InvalidState(State actual);
    error TokenDeltaMismatch();
    error Reentrant();
    error FundingAuthorityAlreadyBound();
    error InvalidFundingAuthority();
    error EntitlementRepresentationMismatch();
    error InvalidFundingSource();
    error InvalidProofMode(uint8 mode);
    error InvalidEntitlement();
    error EntitlementAlreadyConsumed(uint256 index);
    error ClaimAlreadyConsumed(bytes32 claimIdentityHash);
    error InvalidTableProof();
    error InvalidClaimProof();
    error LiabilityExceeded();

    modifier onlyAuthority() {
        if (msg.sender != fundingAuthority) revert OnlyOperationAuthority(msg.sender);
        _;
    }

    modifier nonReentrant() {
        if (_entered) revert Reentrant();
        _entered = true;
        _;
        _entered = false;
    }

    event EntitlementWithdrawn(
        bytes32 indexed operationId,
        uint256 indexed entitlementIndex,
        address indexed beneficiary,
        uint256 amount,
        ProofMode requiredMode,
        ProofObservation optionalProofObservation,
        uint256 claimedAmountAfter,
        uint256 claimedCountAfter
    );
    event EntitlementOperationClosed(bytes32 indexed operationId, uint256 amount, uint256 count);

    constructor(address authority_, IEntitlementProofModeSource proofModeSource_) {
        if (authority_ == address(0) || address(proofModeSource_) == address(0)) revert InvalidOperation();
        operationAuthority = authority_;
        proofModeSource = proofModeSource_;
        fundingAuthority = authority_;
    }

    /// @notice Permanently binds the reserve/controller that may create and fund operations.
    function bindFundingAuthority(address authority_) external override {
        if (msg.sender != operationAuthority) revert OnlyOperationAuthority(msg.sender);
        if (fundingAuthorityBound) revert FundingAuthorityAlreadyBound();
        if (authority_ == address(0)) revert InvalidFundingAuthority();
        fundingAuthority = authority_;
        fundingAuthorityBound = true;
    }

    function create(
        bytes32 operationId,
        bytes32 allocationBindingRoot,
        bytes32 realizedStatementRoot,
        IERC20 token,
        uint256 amount,
        address residualRecipient
    ) external onlyAuthority {
        if (
            operationId == bytes32(0) || allocationBindingRoot == bytes32(0) || realizedStatementRoot == bytes32(0)
                || address(token) == address(0) || amount == 0 || residualRecipient == address(0)
        ) revert InvalidOperation();
        if (_operations[operationId].state != State.None || _entitlementOperations[operationId].state != State.None) {
            revert InvalidState(_operations[operationId].state);
        }
        _operations[operationId] =
            Operation(State.Created, allocationBindingRoot, realizedStatementRoot, token, amount, residualRecipient);
    }

    function fund(bytes32 operationId) external onlyAuthority nonReentrant {
        Operation storage current = _operations[operationId];
        if (current.state != State.Created) revert InvalidState(current.state);
        uint256 reserveBefore = current.token.balanceOf(msg.sender);
        uint256 allocatorBefore = current.token.balanceOf(address(this));
        if (!current.token.transferFrom(msg.sender, address(this), current.amount)) revert TokenDeltaMismatch();
        if (
            reserveBefore < current.token.balanceOf(msg.sender)
                || reserveBefore - current.token.balanceOf(msg.sender) != current.amount
                || current.token.balanceOf(address(this)) < allocatorBefore
                || current.token.balanceOf(address(this)) - allocatorBefore != current.amount
        ) {
            revert TokenDeltaMismatch();
        }
        current.state = State.Funded;
        fundingSource[operationId] = msg.sender;
    }

    /// @notice Returns funded legacy capital to the reserve that supplied it.
    /// @dev Funding is cancellable only before any downstream reliance transition.
    function cancelAndRefund(bytes32 operationId) external onlyAuthority nonReentrant {
        Operation storage current = _operations[operationId];
        if (current.state != State.Funded) revert InvalidState(current.state);
        address source = fundingSource[operationId];
        if (source == address(0)) revert InvalidFundingSource();

        uint256 allocatorBefore = current.token.balanceOf(address(this));
        uint256 sourceBefore = current.token.balanceOf(source);
        current.state = State.Cancelled;
        if (!current.token.transfer(source, current.amount)) revert TokenDeltaMismatch();
        if (
            allocatorBefore < current.token.balanceOf(address(this))
                || allocatorBefore - current.token.balanceOf(address(this)) != current.amount
                || current.token.balanceOf(source) < sourceBefore
                || current.token.balanceOf(source) - sourceBefore != current.amount
        ) revert TokenDeltaMismatch();
    }

    function operation(bytes32 operationId) external view returns (Operation memory) {
        return _operations[operationId];
    }

    /// @notice Creates the successor funding record from an admitted entitlement
    ///         tuple, keeping those roots distinct from the V2 statement-root ABI.
    function createEntitlement(
        bytes32 operationId,
        bytes32 allocationBindingRoot,
        bytes32 descriptorRoot,
        bytes32 evmEntitlementTableRoot,
        uint256 entitlementCount,
        uint256 entitlementTotal,
        bytes32 allocationClaimRoot,
        bytes32 beneficiaryProfileWord,
        IERC20 token,
        uint256 amount,
        address residualRecipient
    ) external onlyAuthority {
        if (
            operationId == bytes32(0) || allocationBindingRoot == bytes32(0) || descriptorRoot == bytes32(0)
                || evmEntitlementTableRoot == bytes32(0) || entitlementCount == 0 || entitlementTotal == 0
                || allocationClaimRoot == bytes32(0) || !_validBeneficiaryProfile(beneficiaryProfileWord)
                || address(token) == address(0) || amount == 0 || residualRecipient == address(0)
                || entitlementTotal != amount
        ) revert InvalidOperation();
        if (_operations[operationId].state != State.None || _entitlementOperations[operationId].state != State.None) {
            revert InvalidState(_entitlementOperations[operationId].state);
        }
        _entitlementOperations[operationId] = IShortfallEntitlementAllocatorV1.EntitlementOperation(
            State.Created,
            allocationBindingRoot,
            descriptorRoot,
            evmEntitlementTableRoot,
            entitlementCount,
            entitlementTotal,
            allocationClaimRoot,
            beneficiaryProfileWord,
            token,
            amount,
            residualRecipient,
            address(0)
        );
    }

    function fundEntitlement(bytes32 operationId) external onlyAuthority nonReentrant {
        IShortfallEntitlementAllocatorV1.EntitlementOperation storage current = _entitlementOperations[operationId];
        if (current.state != State.Created) revert InvalidState(current.state);
        uint256 reserveBefore = current.token.balanceOf(msg.sender);
        uint256 allocatorBefore = current.token.balanceOf(address(this));
        if (!current.token.transferFrom(msg.sender, address(this), current.amount)) revert TokenDeltaMismatch();
        if (
            reserveBefore < current.token.balanceOf(msg.sender)
                || reserveBefore - current.token.balanceOf(msg.sender) != current.amount
                || current.token.balanceOf(address(this)) < allocatorBefore
                || current.token.balanceOf(address(this)) - allocatorBefore != current.amount
        ) revert TokenDeltaMismatch();
        current.state = State.Funded;
        fundingSource[operationId] = msg.sender;
    }

    /// @notice Returns a funded pre-activation operation to the exact source that funded it.
    function cancelAndRefundEntitlement(bytes32 operationId) external onlyAuthority nonReentrant {
        IShortfallEntitlementAllocatorV1.EntitlementOperation storage current = _entitlementOperations[operationId];
        if (current.state != State.Funded) revert InvalidState(current.state);
        address source = fundingSource[operationId];
        if (source == address(0)) revert InvalidFundingSource();

        uint256 allocatorBefore = current.token.balanceOf(address(this));
        uint256 sourceBefore = current.token.balanceOf(source);
        current.state = State.Cancelled;
        if (!current.token.transfer(source, current.amount)) revert TokenDeltaMismatch();
        if (
            allocatorBefore < current.token.balanceOf(address(this))
                || allocatorBefore - current.token.balanceOf(address(this)) != current.amount
                || current.token.balanceOf(source) < sourceBefore
                || current.token.balanceOf(source) - sourceBefore != current.amount
        ) revert TokenDeltaMismatch();
    }

    function entitlementOperation(bytes32 operationId)
        external
        view
        returns (IShortfallEntitlementAllocatorV1.EntitlementOperation memory)
    {
        return _entitlementOperations[operationId];
    }

    /// @notice Makes a funded successor allocation executable only after its
    ///         deployed logical representation matches the admitted tuple.
    function activateEntitlement(bytes32 operationId, IEntitlementRepresentationV1 representation)
        external
        onlyAuthority
    {
        IShortfallEntitlementAllocatorV1.EntitlementOperation storage current = _entitlementOperations[operationId];
        if (current.state != State.Funded) revert InvalidState(current.state);
        if (
            address(representation).code.length == 0 || representation.logicalRoot() != current.evmEntitlementTableRoot
                || representation.entitlementCount() != current.entitlementCount
                || representation.entitlementTotal() != current.entitlementTotal
                || current.amount != current.entitlementTotal
        ) revert EntitlementRepresentationMismatch();
        current.representation = address(representation);
        outstandingLiability[operationId] = current.entitlementTotal;
        current.state = State.Activated;
    }

    /// @notice Atomically consumes one activated entitlement and pays its stable beneficiary.
    /// @dev The table opening is always verified. Allocation proof enforcement follows the live
    ///      governed mode strengthened by the caller's minimum assurance requirement.
    function withdraw(
        bytes32 operationId,
        EntitlementOpening calldata opening,
        bytes32[] calldata tableSiblings,
        bool allocationProofProvided,
        bytes32[] calldata allocationSiblings,
        ProofMode minimumMode
    ) external nonReentrant {
        EntitlementOperation storage current = _entitlementOperations[operationId];
        if (current.state != State.Activated && current.state != State.Claims) revert InvalidState(current.state);
        uint8 liveMode = proofModeSource.currentEntitlementProofMode();
        if (liveMode > uint8(ProofMode.Required)) revert InvalidProofMode(liveMode);
        if (uint8(minimumMode) > uint8(ProofMode.Required)) revert InvalidProofMode(uint8(minimumMode));
        ProofMode requiredMode = liveMode > uint8(minimumMode) ? ProofMode(liveMode) : minimumMode;

        if (
            opening.index >= current.entitlementCount || opening.beneficiary == address(0)
                || opening.beneficiary == address(this) || opening.amount == 0 || opening.claimIdentityUtf8.length == 0
        ) revert InvalidEntitlement();
        bytes32 claimIdentityHash = _canonicalClaimIdentityHash(opening.claimIdentityUtf8);
        uint256 wordIndex = opening.index >> 8;
        uint256 bit = uint256(1) << (opening.index & 255);
        if ((_consumedWords[operationId][wordIndex] & bit) != 0) revert EntitlementAlreadyConsumed(opening.index);
        if (consumedClaimIdentity[operationId][claimIdentityHash]) revert ClaimAlreadyConsumed(claimIdentityHash);

        bytes32 commitment = _entitlementCommitment(current, operationId, opening, claimIdentityHash);
        (bool tablePathValid, bytes32 tableMembersRoot) =
            _orderedPathRoot(commitment, opening.index, current.entitlementCount, tableSiblings, TABLE_NODE_DOMAIN);
        if (!tablePathValid) revert InvalidTableProof();
        bytes32 tableRoot = keccak256(
            abi.encodePacked(
                TABLE_ROOT_DOMAIN,
                tableMembersRoot,
                bytes32(current.entitlementCount),
                bytes32(current.entitlementTotal)
            )
        );
        if (tableRoot != current.evmEntitlementTableRoot) revert InvalidTableProof();

        bytes32 claimLeaf = keccak256(
            abi.encode(
                CLAIM_LEAF_DOMAIN,
                current.allocationBindingRoot,
                operationId,
                opening.index,
                claimIdentityHash,
                opening.beneficiary,
                opening.amount,
                current.beneficiaryProfileWord
            )
        );
        bool allocationProofValid;
        if (allocationProofProvided) {
            (bool allocationPathValid, bytes32 calculatedClaimRoot) = _orderedPathRoot(
                claimLeaf, opening.index, current.entitlementCount, allocationSiblings, CLAIM_NODE_DOMAIN
            );
            allocationProofValid = allocationPathValid && calculatedClaimRoot == current.allocationClaimRoot;
        }
        if (requiredMode == ProofMode.Required && (!allocationProofProvided || !allocationProofValid)) {
            revert InvalidClaimProof();
        }
        ProofObservation observation = !allocationProofProvided
            ? ProofObservation.NotProvided
            : (allocationProofValid ? ProofObservation.Valid : ProofObservation.Invalid);

        uint256 amountAfter = claimedAmount[operationId] + opening.amount;
        uint256 countAfter = claimedCount[operationId] + 1;
        if (amountAfter > current.entitlementTotal || countAfter > current.entitlementCount) {
            revert LiabilityExceeded();
        }
        if (opening.amount > outstandingLiability[operationId]) revert LiabilityExceeded();

        // Consume and update liabilities before transferring. Any failed token postcondition
        // reverts these writes atomically.
        _consumedWords[operationId][wordIndex] |= bit;
        consumedClaimIdentity[operationId][claimIdentityHash] = true;
        claimedAmount[operationId] = amountAfter;
        claimedCount[operationId] = countAfter;
        outstandingLiability[operationId] -= opening.amount;
        current.state = State.Claims;

        uint256 allocatorBefore = current.token.balanceOf(address(this));
        uint256 beneficiaryBefore = current.token.balanceOf(opening.beneficiary);
        if (!current.token.transfer(opening.beneficiary, opening.amount)) revert TokenDeltaMismatch();
        if (
            allocatorBefore < current.token.balanceOf(address(this))
                || allocatorBefore - current.token.balanceOf(address(this)) != opening.amount
                || current.token.balanceOf(opening.beneficiary) < beneficiaryBefore
                || current.token.balanceOf(opening.beneficiary) - beneficiaryBefore != opening.amount
        ) revert TokenDeltaMismatch();

        emit EntitlementWithdrawn(
            operationId,
            opening.index,
            opening.beneficiary,
            opening.amount,
            requiredMode,
            observation,
            amountAfter,
            countAfter
        );
        if (amountAfter == current.entitlementTotal && countAfter == current.entitlementCount) {
            if (outstandingLiability[operationId] != 0) revert LiabilityExceeded();
            current.state = State.Closed;
            emit EntitlementOperationClosed(operationId, amountAfter, countAfter);
        }
    }

    function consumed(bytes32 operationId, uint256 entitlementIndex) external view returns (bool) {
        return (_consumedWords[operationId][entitlementIndex >> 8] & (uint256(1) << (entitlementIndex & 255))) != 0;
    }

    function _entitlementCommitment(
        EntitlementOperation storage current,
        bytes32 operationId,
        EntitlementOpening calldata opening,
        bytes32 claimIdentityHash
    ) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                COMMITMENT_DOMAIN,
                current.allocationBindingRoot,
                operationId,
                opening.index,
                claimIdentityHash,
                opening.beneficiary,
                opening.amount,
                current.beneficiaryProfileWord,
                opening.salt
            )
        );
    }

    function _validBeneficiaryProfile(bytes32 profileWord) private pure returns (bool) {
        return profileWord == SMART_ACCOUNT_PROFILE || profileWord == IMMUTABLE_ADDRESS_PROFILE;
    }

    function _canonicalClaimIdentityHash(bytes calldata claimIdUtf8) private pure returns (bytes32) {
        uint256 remaining = claimIdUtf8.length;
        bytes memory varuint = new bytes(37);
        uint256 cursor;
        while (remaining >= 0x80) {
            varuint[cursor++] = bytes1(uint8((remaining & 0x7f) | 0x80));
            remaining >>= 7;
        }
        // The mask guarantees that this value is at most 0x7f.
        // forge-lint: disable-next-line(unsafe-typecast)
        varuint[cursor++] = bytes1(uint8(remaining & 0x7f));
        bytes memory minimalLength = new bytes(cursor);
        for (uint256 i; i < cursor; ++i) {
            minimalLength[i] = varuint[i];
        }
        return keccak256(abi.encodePacked(bytes1(0x20), minimalLength, claimIdUtf8));
    }

    function _orderedPathRoot(
        bytes32 leaf,
        uint256 index,
        uint256 count,
        bytes32[] calldata siblings,
        bytes32 nodeDomain
    ) private pure returns (bool valid, bytes32 root) {
        if (count == 0 || index >= count) return (false, bytes32(0));
        uint256 depth;
        for (uint256 depthWidth = count; depthWidth > 1; depthWidth = (depthWidth + 1) / 2) {
            ++depth;
        }
        if (siblings.length != depth) return (false, bytes32(0));
        root = leaf;
        uint256 width = count;
        uint256 cursor;
        while (width > 1) {
            bytes32 sibling = siblings[cursor++];
            if ((index & 1) == 0) {
                if (index + 1 >= width && sibling != root) return (false, bytes32(0));
                root = keccak256(abi.encodePacked(nodeDomain, root, sibling));
            } else {
                root = keccak256(abi.encodePacked(nodeDomain, sibling, root));
            }
            index >>= 1;
            width = (width + 1) / 2;
        }
        return (true, root);
    }
}
