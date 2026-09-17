// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPrfStatementAdmission} from "./interfaces/IPrfStatementAdmission.sol";
import {PrfRealizedExecutionVerifierAdapter} from "./PrfRealizedExecutionVerifierAdapter.sol";

/// @notice Minimal custody application for the frozen realized-allocation execution V1 projection.
contract ProductionProRataAllocatorV1 {
    bytes32 private constant OPERATION_DOMAIN = keccak256("prf.realized-allocation-execution.operation-binding.v1");
    bytes32 private constant LEAF_DOMAIN = keccak256("prf.realized-allocation-execution.claim-leaf.v1");
    bytes32 private constant NODE_DOMAIN = keccak256("prf.realized-allocation-execution.claim-node.v1");

    enum State { None, Created, Funded, Activated, Claims, Closed, Cancelled }
    struct Operation {
        State state;
        bytes32 statementRoot;
        bytes32 configurationRoot;
        uint64 configurationEpoch;
        IERC20 token;
        uint256 availableAmount;
        address funder;
        address residualRecipient;
        bytes32 claimRoot;
        uint256 allocationCount;
        uint256 claimedAmount;
        uint256 claimedCount;
    }

    IPrfStatementAdmission public immutable admission;
    address public immutable operationAuthority;
    bool private _entered;
    mapping(bytes32 => Operation) private _operations;
    mapping(bytes32 => mapping(bytes32 => bool)) public claimed;

    error OnlyOperationAuthority(address caller);
    error InvalidOperation(); error InvalidState(State actual); error ReceiptMismatch();
    error ProjectionMismatch(); error InvalidClaim(); error AlreadyClaimed(); error Reentrant(); error TokenDeltaMismatch();

    modifier onlyAuthority() { if (msg.sender != operationAuthority) revert OnlyOperationAuthority(msg.sender); _; }
    modifier nonReentrant() { if (_entered) revert Reentrant(); _entered = true; _; _entered = false; }

    constructor(IPrfStatementAdmission admission_, address authority_) {
        require(address(admission_) != address(0) && authority_ != address(0), "PRA: zero value");
        admission = admission_; operationAuthority = authority_;
    }

    function create(bytes32 operationId, bytes32 statementRoot, bytes32 configurationRoot, uint64 configurationEpoch,
        IERC20 token, uint256 availableAmount, address residualRecipient) external onlyAuthority {
        if (operationId == bytes32(0) || statementRoot == bytes32(0) || configurationRoot == bytes32(0)
            || address(token) == address(0) || availableAmount == 0 || residualRecipient == address(0)) revert InvalidOperation();
        if (_operations[operationId].state != State.None) revert InvalidState(_operations[operationId].state);
        _operations[operationId] = Operation(State.Created, statementRoot, configurationRoot, configurationEpoch, token,
            availableAmount, address(0), residualRecipient, bytes32(0), 0, 0, 0);
    }

    function fund(bytes32 operationId) external onlyAuthority nonReentrant {
        Operation storage op = _operations[operationId]; if (op.state != State.Created) revert InvalidState(op.state);
        uint256 sourceBefore = op.token.balanceOf(msg.sender); uint256 beforeBalance = op.token.balanceOf(address(this));
        _callTransferFrom(op.token, msg.sender, address(this), op.availableAmount);
        if (sourceBefore - op.token.balanceOf(msg.sender) != op.availableAmount || op.token.balanceOf(address(this)) - beforeBalance != op.availableAmount) revert TokenDeltaMismatch();
        op.funder = msg.sender; op.state = State.Funded;
    }

    function activate(bytes32 operationId, bytes32 receiptId, bytes calldata publicValues) external onlyAuthority {
        Operation storage op = _operations[operationId]; if (op.state != State.Funded) revert InvalidState(op.state);
        IPrfStatementAdmission.AdmissionReceipt memory receipt = admission.admissionReceipt(receiptId);
        if (!receipt.exists || receipt.statementRoot != op.statementRoot || receipt.configurationRoot != op.configurationRoot
            || receipt.configurationEpoch != op.configurationEpoch || receipt.publicValuesDigest != sha256(publicValues)) revert ReceiptMismatch();
        PrfRealizedExecutionVerifierAdapter.ExecutionPublicValues memory p =
            PrfRealizedExecutionVerifierAdapter(receipt.verifierAdapter).decodePublicValues(publicValues);
        bytes32 binding = keccak256(abi.encode(OPERATION_DOMAIN, block.chainid, address(this), address(op.token), operationId, op.availableAmount));
        if (p.statementRoot != op.statementRoot || p.operationBinding != binding || p.token != address(op.token)
            || p.allocator != address(this) || p.chainId != block.chainid || p.operationId != operationId
            || p.availableAmount != op.availableAmount || p.totalAllocated != op.availableAmount || p.residualAmount != 0 || p.allocationCount == 0) revert ProjectionMismatch();
        op.claimRoot = p.claimRoot; op.allocationCount = p.allocationCount; op.state = State.Activated;
    }

    function claim(bytes32 operationId, bytes calldata claimId, address recipient, uint256 amount,
        bytes32[] calldata proof, bool[] calldata siblingIsLeft) external nonReentrant {
        Operation storage op = _operations[operationId];
        if (op.state != State.Activated && op.state != State.Claims) revert InvalidState(op.state);
        if (recipient == address(0) || amount == 0 || proof.length != siblingIsLeft.length || proof.length != _depth(op.allocationCount)) revert InvalidClaim();
        bytes32 leaf = keccak256(abi.encode(LEAF_DOMAIN, _binding(op, operationId), keccak256(claimId), recipient, amount));
        if (claimed[operationId][leaf]) revert AlreadyClaimed();
        bytes32 node = leaf;
        for (uint256 i; i < proof.length; ++i) node = siblingIsLeft[i] ? keccak256(abi.encode(NODE_DOMAIN, proof[i], node)) : keccak256(abi.encode(NODE_DOMAIN, node, proof[i]));
        if (node != op.claimRoot || op.claimedAmount + amount > op.availableAmount || op.claimedCount == op.allocationCount) revert InvalidClaim();
        claimed[operationId][leaf] = true; op.claimedAmount += amount; ++op.claimedCount; op.state = State.Claims;
        _transferExact(op.token, recipient, amount);
    }

    function close(bytes32 operationId) external {
        Operation storage op = _operations[operationId]; if (op.state != State.Claims) revert InvalidState(op.state);
        if (op.claimedAmount != op.availableAmount || op.claimedCount != op.allocationCount) revert InvalidClaim();
        op.state = State.Closed; // V1 residual is proof-required to be zero; no residual payout exists.
    }

    function cancel(bytes32 operationId) external onlyAuthority nonReentrant {
        Operation storage op = _operations[operationId];
        if (op.state == State.Created) { op.state = State.Cancelled; return; }
        if (op.state != State.Funded) revert InvalidState(op.state);
        op.state = State.Cancelled; _transferExact(op.token, op.funder, op.availableAmount);
    }
    function operation(bytes32 operationId) external view returns (Operation memory) { return _operations[operationId]; }
    function _binding(Operation storage op, bytes32 operationId) private view returns (bytes32) { return keccak256(abi.encode(OPERATION_DOMAIN, block.chainid, address(this), address(op.token), operationId, op.availableAmount)); }
    function _depth(uint256 n) private pure returns (uint256 d) { while (n > 1) { n = (n + 1) / 2; ++d; } }
    function _callTransferFrom(IERC20 token, address from, address to, uint256 amount) private { require(token.transferFrom(from, to, amount), "PRA: transferFrom failed"); }
    function _transferExact(IERC20 token, address to, uint256 amount) private {
        uint256 fromBefore = token.balanceOf(address(this)); uint256 toBefore = token.balanceOf(to);
        require(token.transfer(to, amount), "PRA: transfer failed");
        if (fromBefore - token.balanceOf(address(this)) != amount || token.balanceOf(to) - toBefore != amount) revert TokenDeltaMismatch();
    }
}
