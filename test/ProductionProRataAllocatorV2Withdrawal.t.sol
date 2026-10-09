// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ProductionProRataAllocatorV2} from "../src/applications/pro-rata/ProductionProRataAllocatorV2.sol";
import {IShortfallAllocatorV2} from "../src/interfaces/IShortfallAllocatorV2.sol";
import {IShortfallEntitlementAllocatorV1} from "../src/interfaces/IShortfallEntitlementAllocatorV1.sol";
import {MockEntitlementProofModeSource} from "./mocks/MockEntitlementProofModeSource.sol";
import {
    PublicPackedEntitlementRepresentationV1
} from "../src/applications/pro-rata/PublicPackedEntitlementRepresentationV1.sol";

contract V2WithdrawalToken is ERC20 {
    bool public feeOnTransfer;

    constructor() ERC20("Withdrawal", "WDR") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFeeOnTransfer(bool enabled) external {
        feeOnTransfer = enabled;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (!feeOnTransfer || value == 0) return super.transfer(to, value);
        _transfer(_msgSender(), to, value - 1);
        _transfer(_msgSender(), address(this), 1);
        return true;
    }
}

contract ProductionProRataAllocatorV2WithdrawalTest is Test {
    bytes32 private constant OP = keccak256("withdraw-operation");
    bytes32 private constant BINDING = keccak256("withdraw-allocation-binding");
    bytes32 private constant PROFILE = keccak256("smart-account-v1");
    bytes32 private constant COMMITMENT_DOMAIN = keccak256("prf.source-bound-entitlement.commitment.v1");
    bytes32 private constant TABLE_NODE_DOMAIN = keccak256("prf.source-bound-entitlement.table-node.v1");
    bytes32 private constant TABLE_ROOT_DOMAIN = keccak256("prf.source-bound-entitlement.table-root.v1");
    bytes32 private constant CLAIM_LEAF_DOMAIN = keccak256("prf.source-bound-entitlement.claim-leaf.v1");
    bytes32 private constant CLAIM_NODE_DOMAIN = keccak256("prf.source-bound-entitlement.claim-node.v1");
    bytes32 private constant SALT_A = keccak256("salt-a");
    bytes32 private constant SALT_B = keccak256("salt-b");
    address private constant BENEFICIARY_A = address(0xA11CE);
    address private constant BENEFICIARY_B = address(0xB0B);

    V2WithdrawalToken private token;
    MockEntitlementProofModeSource private modeSource;
    ProductionProRataAllocatorV2 private allocator;
    PublicPackedEntitlementRepresentationV1 private representation;
    bytes32[] private commitments;
    bytes32[] private claimLeaves;

    function setUp() public {
        token = new V2WithdrawalToken();
        modeSource = new MockEntitlementProofModeSource();
        allocator = new ProductionProRataAllocatorV2(address(this), modeSource);
        commitments = new bytes32[](2);
        claimLeaves = new bytes32[](2);
        commitments[0] = _commitment(0, "claim-a", BENEFICIARY_A, 4, SALT_A);
        commitments[1] = _commitment(1, "claim-b", BENEFICIARY_B, 6, SALT_B);
        claimLeaves[0] = _claimLeaf(0, "claim-a", BENEFICIARY_A, 4);
        claimLeaves[1] = _claimLeaf(1, "claim-b", BENEFICIARY_B, 6);
        representation = new PublicPackedEntitlementRepresentationV1(commitments, 10);

        token.mint(address(this), 10);
        token.approve(address(allocator), 10);
        allocator.createEntitlement(
            OP,
            BINDING,
            keccak256("committed-immutable-table-v1 descriptor"),
            representation.logicalRoot(),
            2,
            10,
            _node(CLAIM_NODE_DOMAIN, claimLeaves[0], claimLeaves[1]),
            PROFILE,
            token,
            10,
            address(0xD00D)
        );
        allocator.fundEntitlement(OP);
        allocator.activateEntitlement(OP, representation);
    }

    function test_RequestedNoProofAndInvalidOptionalProofExecuteAndCloseExactly() public {
        bytes32[] memory tablePathA = _one(commitments[1]);
        bytes32[] memory noProof = new bytes32[](0);
        allocator.withdraw(
            OP,
            _opening(0, "claim-a", BENEFICIARY_A, 4, SALT_A),
            tablePathA,
            false,
            noProof,
            ProductionProRataAllocatorV2.ProofMode.Requested
        );
        assertEq(token.balanceOf(BENEFICIARY_A), 4);
        assertEq(allocator.outstandingLiability(OP), 6);
        assertEq(allocator.claimedAmount(OP), 4);
        assertEq(allocator.claimedCount(OP), 1);
        assertEq(uint8(allocator.entitlementOperation(OP).state), uint8(IShortfallAllocatorV2.State.Claims));

        bytes32[] memory invalidProof = _one(keccak256("wrong sibling"));
        allocator.withdraw(
            OP,
            _opening(1, "claim-b", BENEFICIARY_B, 6, SALT_B),
            _one(commitments[0]),
            true,
            invalidProof,
            ProductionProRataAllocatorV2.ProofMode.Requested
        );
        assertEq(token.balanceOf(BENEFICIARY_B), 6);
        assertEq(token.balanceOf(address(allocator)), 0);
        assertEq(allocator.outstandingLiability(OP), 0);
        assertEq(uint8(allocator.entitlementOperation(OP).state), uint8(IShortfallAllocatorV2.State.Closed));
    }

    function test_RequiredRejectsMissingAndInvalidButAcceptsValidProof() public {
        modeSource.setMode(1);
        bytes32[] memory noProof = new bytes32[](0);
        vm.expectRevert(ProductionProRataAllocatorV2.InvalidClaimProof.selector);
        allocator.withdraw(
            OP,
            _opening(0, "claim-a", BENEFICIARY_A, 4, SALT_A),
            _one(commitments[1]),
            false,
            noProof,
            ProductionProRataAllocatorV2.ProofMode.Requested
        );
        vm.expectRevert(ProductionProRataAllocatorV2.InvalidClaimProof.selector);
        allocator.withdraw(
            OP,
            _opening(0, "claim-a", BENEFICIARY_A, 4, SALT_A),
            _one(commitments[1]),
            true,
            _one(keccak256("wrong sibling")),
            ProductionProRataAllocatorV2.ProofMode.Requested
        );
        assertEq(token.balanceOf(BENEFICIARY_A), 0);
        assertEq(allocator.outstandingLiability(OP), 10);

        allocator.withdraw(
            OP,
            _opening(0, "claim-a", BENEFICIARY_A, 4, SALT_A),
            _one(commitments[1]),
            true,
            _one(claimLeaves[1]),
            ProductionProRataAllocatorV2.ProofMode.Requested
        );
        assertEq(token.balanceOf(BENEFICIARY_A), 4);
    }

    function test_LiveModeAppliesToExistingOperationAndCallerMinimumCannotLowerIt() public {
        modeSource.setMode(1);
        vm.expectRevert(ProductionProRataAllocatorV2.InvalidClaimProof.selector);
        allocator.withdraw(
            OP,
            _opening(0, "claim-a", BENEFICIARY_A, 4, SALT_A),
            _one(commitments[1]),
            false,
            new bytes32[](0),
            ProductionProRataAllocatorV2.ProofMode.Requested
        );
        modeSource.setMode(0);
        vm.expectRevert(ProductionProRataAllocatorV2.InvalidClaimProof.selector);
        allocator.withdraw(
            OP,
            _opening(0, "claim-a", BENEFICIARY_A, 4, SALT_A),
            _one(commitments[1]),
            false,
            new bytes32[](0),
            ProductionProRataAllocatorV2.ProofMode.Required
        );
        allocator.withdraw(
            OP,
            _opening(0, "claim-a", BENEFICIARY_A, 4, SALT_A),
            _one(commitments[1]),
            false,
            new bytes32[](0),
            ProductionProRataAllocatorV2.ProofMode.Requested
        );
        assertEq(token.balanceOf(BENEFICIARY_A), 4);
    }

    function test_TableOpeningSubstitutionAndDuplicateClaimReplayReject() public {
        vm.expectRevert(ProductionProRataAllocatorV2.InvalidTableProof.selector);
        allocator.withdraw(
            OP,
            _opening(0, "claim-a", BENEFICIARY_B, 4, SALT_A),
            _one(commitments[1]),
            false,
            new bytes32[](0),
            ProductionProRataAllocatorV2.ProofMode.Requested
        );
        allocator.withdraw(
            OP,
            _opening(0, "claim-a", BENEFICIARY_A, 4, SALT_A),
            _one(commitments[1]),
            false,
            new bytes32[](0),
            ProductionProRataAllocatorV2.ProofMode.Requested
        );
        vm.expectRevert(
            abi.encodeWithSelector(ProductionProRataAllocatorV2.EntitlementAlreadyConsumed.selector, uint256(0))
        );
        allocator.withdraw(
            OP,
            _opening(0, "claim-a", BENEFICIARY_A, 4, SALT_A),
            _one(commitments[1]),
            false,
            new bytes32[](0),
            ProductionProRataAllocatorV2.ProofMode.Requested
        );
    }

    function test_ClaimAmountOrdinalAndSaltSubstitutionReject() public {
        bytes32[] memory tablePath = _one(commitments[1]);
        vm.expectRevert(ProductionProRataAllocatorV2.InvalidTableProof.selector);
        allocator.withdraw(
            OP,
            _opening(0, "claim-other", BENEFICIARY_A, 4, SALT_A),
            tablePath,
            false,
            new bytes32[](0),
            ProductionProRataAllocatorV2.ProofMode.Requested
        );
        vm.expectRevert(ProductionProRataAllocatorV2.InvalidTableProof.selector);
        allocator.withdraw(
            OP,
            _opening(0, "claim-a", BENEFICIARY_A, 5, SALT_A),
            tablePath,
            false,
            new bytes32[](0),
            ProductionProRataAllocatorV2.ProofMode.Requested
        );
        vm.expectRevert(ProductionProRataAllocatorV2.InvalidTableProof.selector);
        allocator.withdraw(
            OP,
            _opening(0, "claim-a", BENEFICIARY_A, 4, keccak256("wrong salt")),
            tablePath,
            false,
            new bytes32[](0),
            ProductionProRataAllocatorV2.ProofMode.Requested
        );
        vm.expectRevert(ProductionProRataAllocatorV2.InvalidTableProof.selector);
        allocator.withdraw(
            OP,
            _opening(1, "claim-a", BENEFICIARY_A, 4, SALT_A),
            _one(commitments[0]),
            false,
            new bytes32[](0),
            ProductionProRataAllocatorV2.ProofMode.Requested
        );
        assertEq(allocator.claimedCount(OP), 0);
        assertEq(allocator.outstandingLiability(OP), 10);
    }

    function test_FeeOnTransferRollsBackConsumptionAndAccounting() public {
        token.setFeeOnTransfer(true);
        vm.expectRevert(ProductionProRataAllocatorV2.TokenDeltaMismatch.selector);
        allocator.withdraw(
            OP,
            _opening(0, "claim-a", BENEFICIARY_A, 4, SALT_A),
            _one(commitments[1]),
            false,
            new bytes32[](0),
            ProductionProRataAllocatorV2.ProofMode.Requested
        );
        assertFalse(allocator.consumed(OP, 0));
        assertFalse(
            allocator.consumedClaimIdentity(OP, keccak256(abi.encodePacked(bytes1(0x20), bytes1(uint8(7)), "claim-a")))
        );
        assertEq(allocator.claimedAmount(OP), 0);
        assertEq(allocator.claimedCount(OP), 0);
        assertEq(allocator.outstandingLiability(OP), 10);
        assertEq(token.balanceOf(address(allocator)), 10);
        assertEq(token.balanceOf(BENEFICIARY_A), 0);
    }

    function _opening(uint256 index, string memory claim, address beneficiary, uint256 amount, bytes32 salt)
        private
        pure
        returns (ProductionProRataAllocatorV2.EntitlementOpening memory)
    {
        return ProductionProRataAllocatorV2.EntitlementOpening(index, bytes(claim), beneficiary, amount, salt);
    }

    function _commitment(uint256 index, string memory claim, address beneficiary, uint256 amount, bytes32 salt)
        private
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                COMMITMENT_DOMAIN,
                BINDING,
                OP,
                index,
                keccak256(abi.encodePacked(bytes1(0x20), bytes1(uint8(bytes(claim).length)), bytes(claim))),
                beneficiary,
                amount,
                PROFILE,
                salt
            )
        );
    }

    function _claimLeaf(uint256 index, string memory claim, address beneficiary, uint256 amount)
        private
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                CLAIM_LEAF_DOMAIN,
                BINDING,
                OP,
                index,
                keccak256(abi.encodePacked(bytes1(0x20), bytes1(uint8(bytes(claim).length)), bytes(claim))),
                beneficiary,
                amount,
                PROFILE
            )
        );
    }

    function _node(bytes32 domain, bytes32 left, bytes32 right) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(domain, left, right));
    }

    function _one(bytes32 value) private pure returns (bytes32[] memory values) {
        values = new bytes32[](1);
        values[0] = value;
    }
}
