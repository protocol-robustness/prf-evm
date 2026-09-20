// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPrfStatementAdmission} from "../src/interfaces/IPrfStatementAdmission.sol";
import {ISP1Verifier} from "../src/verification/interfaces/ISP1Verifier.sol";
import {MockSP1Verifier} from "./mocks/MockSP1Verifier.sol";
import {PrfRealizedExecutionVerifierAdapter} from "../src/verification/adapters/PrfRealizedExecutionVerifierAdapter.sol";
import {ProductionProRataAllocatorV1} from "../src/applications/pro-rata/ProductionProRataAllocatorV1.sol";

contract ReceiptStore {
    mapping(bytes32 => IPrfStatementAdmission.AdmissionReceipt) internal receipts;
    function set(bytes32 id, IPrfStatementAdmission.AdmissionReceipt calldata receipt) external { receipts[id] = receipt; }
    function admissionReceipt(bytes32 id) external view returns (IPrfStatementAdmission.AdmissionReceipt memory) { return receipts[id]; }
}
contract TestToken is ERC20 { constructor() ERC20("Test", "T") {} function mint(address to, uint256 n) external { _mint(to, n); } }
contract FeeToken is ERC20 {
    constructor() ERC20("Fee", "F") {} function mint(address to, uint256 n) external { _mint(to, n); }
    function _update(address from, address to, uint256 value) internal override { super._update(from, to, value - 1); if (from != address(0)) super._update(from, address(0), 1); }
}

contract OutboundFeeToken is ERC20 {
    address immutable allocator;
    constructor(address allocator_) ERC20("OutboundFee", "OF") { allocator = allocator_; }
    function mint(address to, uint256 n) external { _mint(to, n); }
    function _update(address from, address to, uint256 value) internal override {
        if (from == allocator && to != address(0)) {
            super._update(from, to, value - 1);
            super._update(from, address(0), 1);
        } else {
            super._update(from, to, value);
        }
    }
}

contract ReentrantToken is ERC20 {
    address immutable allocator;
    bytes callback;
    bool public attempted;
    bool public reentrySucceeded;
    constructor(address allocator_) ERC20("Reentrant", "R") { allocator = allocator_; }
    function mint(address to, uint256 n) external { _mint(to, n); }
    function setCallback(bytes calldata callback_) external { callback = callback_; }
    function _update(address from, address to, uint256 value) internal override {
        if (from == allocator && to != address(0) && !attempted) {
            attempted = true;
            (reentrySucceeded,) = allocator.call(callback);
        }
        super._update(from, to, value);
    }
}

contract ProductionProRataAllocatorV1Test is Test {
    bytes32 constant STATEMENT_ROOT = 0xc22333a16df1c1efa352e9daab42ccbd78f4a1d7530ee3ed3cf7527ba62cbd81;
    bytes32 constant OP = keccak256("production-pro-rata-v1");
    bytes32 constant CONFIG = keccak256("config");
    bytes32 constant LEAF_DOMAIN = keccak256("prf.realized-allocation-execution.claim-leaf.v1");
    bytes32 constant NODE_DOMAIN = keccak256("prf.realized-allocation-execution.claim-node.v1");
    bytes32 constant BINDING_DOMAIN = keccak256("prf.realized-allocation-execution.operation-binding.v1");
    bytes32 constant GOLDEN = keccak256("golden-execution-vector");
    ReceiptStore admission;
    TestToken token;
    ProductionProRataAllocatorV1 allocator;
    PrfRealizedExecutionVerifierAdapter adapter;
    address alice = address(0x1111); address bob = address(0x2222); address carol = address(0x3333);

    function setUp() public {
        admission = new ReceiptStore(); token = new TestToken(); token.mint(address(this), 1_000);
        adapter = new PrfRealizedExecutionVerifierAdapter(ISP1Verifier(address(new MockSP1Verifier(bytes32(0), bytes32(0)))), bytes32(uint256(1)), bytes32(uint256(2)));
        allocator = new ProductionProRataAllocatorV1(IPrfStatementAdmission(address(admission)), address(this));
        allocator.create(OP, STATEMENT_ROOT, CONFIG, 7, token, 100, address(0x9999)); token.approve(address(allocator), 100); allocator.fund(OP);
    }

    function test_GoldenRustProjection_DecodesExact384ByteVector() public {
        bytes memory golden = hex"d2196a7baaa9f298fe2fc5bc00454f9455487bb55672083690a7c856d55f33ebc22333a16df1c1efa352e9daab42ccbd78f4a1d7530ee3ed3cf7527ba62cbd812af0c75e9385b5b40631c6b05dcc9271b1398c96373899269d061beec929027f407fae5b4caeb20d77a030a74fa4e2659f7d75505ade3645c825da35ab98afa3000000000000000000000000444444444444444444444444444444444444444400000000000000000000000055555555555555555555555555555555555555550000000000000000000000000000000000000000000000000000000000000001aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa0000000000000000000000000000000000000000000000000000000000000064000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000000000000000000000000000000000000640000000000000000000000000000000000000000000000000000000000000000";
        assertEq(golden.length, 384);
        PrfRealizedExecutionVerifierAdapter.ExecutionPublicValues memory p = adapter.decodePublicValues(golden);
        assertEq(p.statementRoot, STATEMENT_ROOT);
        assertEq(p.operationBinding, 0x2af0c75e9385b5b40631c6b05dcc9271b1398c96373899269d061beec929027f);
        assertEq(p.claimRoot, 0x407fae5b4caeb20d77a030a74fa4e2659f7d75505ade3645c825da35ab98afa3);
        assertEq(p.allocationCount, 3);
        assertEq(p.totalAllocated, 100);
        assertEq(p.residualAmount, 0);
    }

    function test_ClaimsFollowOrderedDuplicateLastTreeAndClose() public {
        (bytes memory pv, bytes32[] memory leaves) = _projection(); _store(pv); allocator.activate(OP, GOLDEN, pv);
        bytes32 ab = _node(leaves[0], leaves[1]); bytes32 cc = _node(leaves[2], leaves[2]);
        bytes32[] memory pa = new bytes32[](2); pa[0] = leaves[1]; pa[1] = cc; bool[] memory ra = new bool[](2);
        allocator.claim(OP, bytes("A"), alice, 50, pa, ra);
        bytes32[] memory pb = new bytes32[](2); pb[0] = leaves[0]; pb[1] = cc; bool[] memory rb = new bool[](2); rb[0] = true;
        allocator.claim(OP, bytes("B"), bob, 30, pb, rb);
        bytes32[] memory pc = new bytes32[](2); pc[0] = leaves[2]; pc[1] = ab; bool[] memory rc = new bool[](2); rc[1] = true;
        allocator.claim(OP, bytes("C"), carol, 20, pc, rc); allocator.close(OP);
        assertEq(token.balanceOf(alice), 50); assertEq(token.balanceOf(bob), 30); assertEq(token.balanceOf(carol), 20);
        assertEq(uint256(allocator.operation(OP).state), uint256(ProductionProRataAllocatorV1.State.Closed));
    }

    function test_HostileVectorsRejectDigestBindingAndMerkleDrift() public {
        (bytes memory pv, bytes32[] memory leaves) = _projection(); _store(pv);
        bytes memory altered = pv; altered[383] = 0x01;
        vm.expectRevert(ProductionProRataAllocatorV1.ReceiptMismatch.selector); allocator.activate(OP, GOLDEN, altered);
        (pv, leaves) = _projection();
        allocator.activate(OP, GOLDEN, pv);
        bytes32[] memory p = new bytes32[](2); p[0] = leaves[1]; p[1] = _node(leaves[2], leaves[2]); bool[] memory right = new bool[](2);
        vm.expectRevert(ProductionProRataAllocatorV1.InvalidClaim.selector); allocator.claim(OP, bytes("A"), alice, 51, p, right);
    }

    function test_FeeTokenFundingRejectsExactDelta() public {
        FeeToken fee = new FeeToken(); fee.mint(address(this), 200);
        ProductionProRataAllocatorV1 a = new ProductionProRataAllocatorV1(IPrfStatementAdmission(address(admission)), address(this));
        bytes32 id = keccak256("fee"); a.create(id, STATEMENT_ROOT, CONFIG, 7, fee, 100, address(1)); fee.approve(address(a), 100);
        vm.expectRevert(ProductionProRataAllocatorV1.TokenDeltaMismatch.selector); a.fund(id);
    }

    function test_OnlyAuthorityCanCreateFundActivateAndCancel() public {
        bytes32 id = keccak256("unauthorized");
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(ProductionProRataAllocatorV1.OnlyOperationAuthority.selector, alice));
        allocator.create(id, STATEMENT_ROOT, CONFIG, 7, token, 100, alice);
        vm.expectRevert(abi.encodeWithSelector(ProductionProRataAllocatorV1.OnlyOperationAuthority.selector, alice)); allocator.fund(OP);
        vm.expectRevert(abi.encodeWithSelector(ProductionProRataAllocatorV1.OnlyOperationAuthority.selector, alice)); allocator.activate(OP, GOLDEN, bytes(""));
        vm.expectRevert(abi.encodeWithSelector(ProductionProRataAllocatorV1.OnlyOperationAuthority.selector, alice)); allocator.cancel(OP);
        vm.stopPrank();
    }

    function test_DuplicateOperationAndPreActivationClaimsReject() public {
        vm.expectRevert(abi.encodeWithSelector(ProductionProRataAllocatorV1.InvalidState.selector, ProductionProRataAllocatorV1.State.Funded));
        allocator.create(OP, STATEMENT_ROOT, CONFIG, 7, token, 100, address(0x9999));
        bytes32[] memory proof = new bytes32[](0); bool[] memory direction = new bool[](0);
        vm.expectRevert(abi.encodeWithSelector(ProductionProRataAllocatorV1.InvalidState.selector, ProductionProRataAllocatorV1.State.Funded));
        allocator.claim(OP, bytes("A"), alice, 50, proof, direction);
    }

    function test_OperationRejectsReceiptFromAnotherConfigurationSnapshot() public {
        (bytes memory pv,) = _projection();
        admission.set(GOLDEN, IPrfStatementAdmission.AdmissionReceipt(true, bytes32(0), bytes32(0), keccak256("other-config"), 8, bytes32(0), bytes32(0), address(adapter), bytes32(0), bytes32(0), adapter.statementSchemaVersion(), adapter.publicValuesSchema(), STATEMENT_ROOT, sha256(pv)));
        vm.expectRevert(ProductionProRataAllocatorV1.ReceiptMismatch.selector); allocator.activate(OP, GOLDEN, pv);
    }

    function test_CancellationRefundsOnlyFundedOperationAndBlocksClaims() public {
        uint256 before = token.balanceOf(address(this));
        allocator.cancel(OP);
        assertEq(token.balanceOf(address(this)), before + 100);
        assertEq(uint256(allocator.operation(OP).state), uint256(ProductionProRataAllocatorV1.State.Cancelled));
        bytes32[] memory proof = new bytes32[](0); bool[] memory direction = new bool[](0);
        vm.expectRevert(abi.encodeWithSelector(ProductionProRataAllocatorV1.InvalidState.selector, ProductionProRataAllocatorV1.State.Cancelled));
        allocator.claim(OP, bytes("A"), alice, 50, proof, direction);
    }

    function test_ActivationPreventsCancellationAndClaimsRejectWrongIdentity() public {
        (bytes memory pv, bytes32[] memory leaves) = _projection(); _store(pv); allocator.activate(OP, GOLDEN, pv);
        vm.expectRevert(abi.encodeWithSelector(ProductionProRataAllocatorV1.InvalidState.selector, ProductionProRataAllocatorV1.State.Activated));
        allocator.cancel(OP);
        bytes32[] memory proof = new bytes32[](2); proof[0] = leaves[1]; proof[1] = _node(leaves[2], leaves[2]); bool[] memory right = new bool[](2);
        vm.expectRevert(ProductionProRataAllocatorV1.InvalidClaim.selector);
        allocator.claim(OP, bytes("wrong-id"), alice, 50, proof, right);
        vm.expectRevert(ProductionProRataAllocatorV1.InvalidClaim.selector);
        allocator.claim(OP, bytes("A"), bob, 50, proof, right);
        allocator.claim(OP, bytes("A"), alice, 50, proof, right);
        vm.expectRevert(ProductionProRataAllocatorV1.AlreadyClaimed.selector);
        allocator.claim(OP, bytes("A"), alice, 50, proof, right);
    }

    function test_OutboundFeeTokenClaimRejectsAndStateRollsBack() public {
        ProductionProRataAllocatorV1 a = new ProductionProRataAllocatorV1(IPrfStatementAdmission(address(admission)), address(this));
        OutboundFeeToken fee = new OutboundFeeToken(address(a)); fee.mint(address(this), 100);
        bytes32 id = keccak256("outbound-fee");
        a.create(id, STATEMENT_ROOT, CONFIG, 7, fee, 100, address(0x9999)); fee.approve(address(a), 100); a.fund(id);
        bytes32 binding = keccak256(abi.encode(BINDING_DOMAIN, block.chainid, address(a), address(fee), id, uint256(100)));
        bytes32 leaf = _leaf(binding, "A", alice, 100);
        bytes memory pv = abi.encode(keccak256("realized-allocation-execution-public-values.v1"), STATEMENT_ROOT, binding, leaf, address(fee), address(a), block.chainid, id, 100, 1, 100, 0);
        _store(pv); a.activate(id, GOLDEN, pv);
        bytes32[] memory proof = new bytes32[](0); bool[] memory direction = new bool[](0);
        vm.expectRevert(ProductionProRataAllocatorV1.TokenDeltaMismatch.selector); a.claim(id, bytes("A"), alice, 100, proof, direction);
        assertFalse(a.claimed(id, leaf));
        assertEq(a.operation(id).claimedAmount, 0);
    }

    function test_ReentrantClaimAttemptCannotConsumeTwice() public {
        ProductionProRataAllocatorV1 a = new ProductionProRataAllocatorV1(IPrfStatementAdmission(address(admission)), address(this));
        ReentrantToken reentrant = new ReentrantToken(address(a)); reentrant.mint(address(this), 100);
        bytes32 id = keccak256("reentrant");
        a.create(id, STATEMENT_ROOT, CONFIG, 7, reentrant, 100, address(0x9999)); reentrant.approve(address(a), 100); a.fund(id);
        bytes32 binding = keccak256(abi.encode(BINDING_DOMAIN, block.chainid, address(a), address(reentrant), id, uint256(100)));
        bytes32 leaf = _leaf(binding, "A", alice, 100);
        bytes memory pv = abi.encode(keccak256("realized-allocation-execution-public-values.v1"), STATEMENT_ROOT, binding, leaf, address(reentrant), address(a), block.chainid, id, 100, 1, 100, 0);
        _store(pv); a.activate(id, GOLDEN, pv);
        bytes32[] memory proof = new bytes32[](0); bool[] memory direction = new bool[](0);
        reentrant.setCallback(abi.encodeCall(a.claim, (id, bytes("A"), alice, uint256(100), proof, direction)));
        a.claim(id, bytes("A"), alice, 100, proof, direction);
        assertTrue(reentrant.attempted());
        assertFalse(reentrant.reentrySucceeded());
        assertEq(reentrant.balanceOf(alice), 100);
        assertEq(a.operation(id).claimedCount, 1);
    }

    function _store(bytes memory pv) internal {
        admission.set(GOLDEN, IPrfStatementAdmission.AdmissionReceipt(true, bytes32(0), bytes32(0), CONFIG, 7, bytes32(0), bytes32(0), address(adapter), bytes32(0), bytes32(0), adapter.statementSchemaVersion(), adapter.publicValuesSchema(), STATEMENT_ROOT, sha256(pv)));
    }
    function _projection() internal view returns (bytes memory pv, bytes32[] memory leaves) {
        bytes32 binding = keccak256(abi.encode(BINDING_DOMAIN, block.chainid, address(allocator), address(token), OP, uint256(100)));
        leaves = new bytes32[](3); leaves[0] = _leaf(binding, "A", alice, 50); leaves[1] = _leaf(binding, "B", bob, 30); leaves[2] = _leaf(binding, "C", carol, 20);
        pv = abi.encode(keccak256("realized-allocation-execution-public-values.v1"), STATEMENT_ROOT, binding, _node(_node(leaves[0], leaves[1]), _node(leaves[2], leaves[2])), address(token), address(allocator), block.chainid, OP, 100, 3, 100, 0);
    }
    function _leaf(bytes32 binding, string memory id, address recipient, uint256 amount) internal pure returns (bytes32) { return keccak256(abi.encode(LEAF_DOMAIN, binding, keccak256(bytes(id)), recipient, amount)); }
    function _node(bytes32 left, bytes32 right) internal pure returns (bytes32) { return keccak256(abi.encode(NODE_DOMAIN, left, right)); }
}
