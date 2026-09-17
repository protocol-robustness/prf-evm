// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SP1Verifier} from "@sp1-contracts/v6.1.0/SP1VerifierGroth16.sol";

import {ISP1Verifier} from "../src/ISP1Verifier.sol";
import {IPrfStatementAdmission} from "../src/interfaces/IPrfStatementAdmission.sol";
import {PrfChainInstanceGenesis} from "../src/PrfChainInstanceGenesis.sol";
import {PrfRealizedExecutionVerifierAdapter} from "../src/PrfRealizedExecutionVerifierAdapter.sol";
import {PrfStatementAdmission} from "../src/PrfStatementAdmission.sol";
import {PrfVerifierRegistry} from "../src/PrfVerifierRegistry.sol";
import {ProductionProRataAllocatorV1} from "../src/ProductionProRataAllocatorV1.sol";
import {SewConfigurationExecutor} from "../src/SewConfigurationExecutor.sol";
import {SewGovernanceAuthorityAdapter} from "../src/SewGovernanceAuthorityAdapter.sol";

contract EtchedFixtureERC20 is ERC20 {
    constructor() ERC20("Etched fixture token", "EFT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice End-to-end conformance for the committed realized-execution fixture.
contract RealizedExecutionProofEtchedIntegrationTest is Test {
    address internal constant COMMITTED_TOKEN = 0x4444444444444444444444444444444444444444;
    address internal constant COMMITTED_ALLOCATOR = 0x5555555555555555555555555555555555555555;
    address internal constant RECIPIENT_A = 0x1111111111111111111111111111111111111111;

    bytes32 internal constant OPERATION_ID =
        0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;
    bytes32 internal constant VERIFIER_ID = keccak256("realized-allocation-execution.v1");
    bytes32 internal constant PROTOCOL_ROOT = keccak256("etched-realized-execution-protocol");
    bytes32 internal constant AUTHORITY_STATE_ROOT = keccak256("etched-realized-execution-authority");
    bytes32 internal constant CONFIG_ROOT_0 = keccak256("etched-realized-execution-config-0");
    bytes32 internal constant CONFIG_ROOT_1 = keccak256("etched-realized-execution-config-1");
    bytes32 internal constant CHAIN_INSTANCE_ROOT = keccak256("etched-realized-execution-chain-instance");
    bytes32 internal constant DECISION_ROOT = keccak256("etched-realized-execution-decision");
    bytes32 private registryVkeyOverride;
    bytes32 private registryElfOverride;
    bytes32 private registryStatementSchemaOverride;
    bytes32 private registryPublicSchemaOverride;

    // Pinned siblings from the fixture's ordered three-leaf, duplicate-last tree.
    bytes32 internal constant LEAF_B =
        0x23472ad42041455ea0d2ae5aaf7b6cb8f440622e2b53ad010bd0bdf8c566d227;
    bytes32 internal constant LEAF_C =
        0xf08fd8ef2d0ea21606cc29d5ccfb387800f0fa09d79858ee4432e903ed98e612;
    bytes32 internal constant DUPLICATE_LAST_C_NODE =
        0xeee956f4fa51f2da4339f114a8b2b18f726735501a5cadf5b572016b5175c63e;

    function test_RealFixtureAdmitsActivatesAndClaimsAtCommittedAddresses() public {
        vm.chainId(1);
        (bytes32 vkey, bytes32 elfSha256, bytes memory publicValues, bytes memory proof, string memory programId) =
            _readFixture();
        PrfRealizedExecutionVerifierAdapter.ExecutionPublicValues memory projection =
            _projection(publicValues);

        assertEq(projection.chainId, 1);
        assertEq(projection.token, COMMITTED_TOKEN);
        assertEq(projection.allocator, COMMITTED_ALLOCATOR);
        assertEq(projection.operationId, OPERATION_ID);
        assertEq(projection.domain, keccak256("realized-allocation-execution-public-values.v1"));
        assertEq(projection.statementRoot, 0xc22333a16df1c1efa352e9daab42ccbd78f4a1d7530ee3ed3cf7527ba62cbd81);
        assertEq(projection.operationBinding, 0x2af0c75e9385b5b40631c6b05dcc9271b1398c96373899269d061beec929027f);
        assertEq(projection.claimRoot, 0x407fae5b4caeb20d77a030a74fa4e2659f7d75505ade3645c825da35ab98afa3);
        assertEq(projection.availableAmount, 100);
        assertEq(projection.allocationCount, 3);
        assertEq(projection.totalAllocated, 100);
        assertEq(projection.residualAmount, 0);
        assertEq(publicValues.length, 384);
        assertEq(programId, "realized-execution-sp1-program.v1");
        assertEq(vkey, 0x00c6ef567e2dba426bca4e4280c5a3a5b85ba6d5d090a9b2b4dcb7762a36739a);
        assertEq(elfSha256, 0x549f67119f3ef3ffb7f6179ed88fa0a9604707c08df3459287831643f58ce70a);
        assertEq(keccak256(bytes(programId)), keccak256("realized-execution-sp1-program.v1"));
        assertEq(keccak256("realized-allocation-execution-public-values.v1"),
            keccak256(bytes("realized-allocation-execution-public-values.v1")));

        PrfStatementAdmission admission = _deployAdmission(vkey, elfSha256, programId);
        _etchCommittedContracts(admission);

        EtchedFixtureERC20 token = EtchedFixtureERC20(COMMITTED_TOKEN);
        ProductionProRataAllocatorV1 allocator = ProductionProRataAllocatorV1(COMMITTED_ALLOCATOR);
        assertEq(address(allocator.admission()), address(admission));
        assertEq(allocator.operationAuthority(), address(this));

        token.mint(address(this), projection.availableAmount);
        allocator.create(
            OPERATION_ID,
            projection.statementRoot,
            CONFIG_ROOT_1,
            1,
            IERC20(COMMITTED_TOKEN),
            projection.availableAmount,
            address(0x9999)
        );
        token.approve(COMMITTED_ALLOCATOR, projection.availableAmount);
        allocator.fund(OPERATION_ID);

        bytes32 receiptId = admission.admitStatement(VERIFIER_ID, projection.statementRoot, proof, publicValues);
        IPrfStatementAdmission.AdmissionReceipt memory receipt = admission.admissionReceipt(receiptId);
        assertEq(receipt.programVKey, vkey);
        assertEq(receipt.programElfSha256, elfSha256);
        assertEq(receipt.statementSchemaVersionHash, keccak256("realized-allocation-statement.v1"));
        assertEq(receipt.publicValuesSchema, keccak256(bytes("realized-allocation-execution-public-values.v1")));
        assertEq(PrfRealizedExecutionVerifierAdapter(receipt.verifierAdapter).programVKey(), vkey);
        assertEq(PrfRealizedExecutionVerifierAdapter(receipt.verifierAdapter).programElfSha256(), elfSha256);

        bytes memory alteredPublicValues = _copy(publicValues);
        alteredPublicValues[alteredPublicValues.length - 1] = 0x01;
        vm.expectRevert(ProductionProRataAllocatorV1.ReceiptMismatch.selector);
        allocator.activate(OPERATION_ID, receiptId, alteredPublicValues);

        allocator.activate(OPERATION_ID, receiptId, publicValues);

        assertEq(projection.operationBinding, _binding());
        assertEq(allocator.operation(OPERATION_ID).allocationCount, 3);
        assertEq(LEAF_B, _leaf(projection.operationBinding, "B", address(0x2222222222222222222222222222222222222222), 30));
        assertEq(LEAF_C, _leafC(projection.operationBinding));
        assertEq(DUPLICATE_LAST_C_NODE, _node(LEAF_C, LEAF_C));
        assertEq(
            projection.claimRoot,
            _node(_node(_leaf(projection.operationBinding, "A", RECIPIENT_A, 50), LEAF_B), DUPLICATE_LAST_C_NODE)
        );

        bytes32[] memory proofA = new bytes32[](2);
        proofA[0] = LEAF_B;
        proofA[1] = DUPLICATE_LAST_C_NODE;
        bool[] memory siblingIsLeftA = new bool[](2);
        allocator.claim(OPERATION_ID, bytes("A"), RECIPIENT_A, 50, proofA, siblingIsLeftA);

        assertEq(token.balanceOf(RECIPIENT_A), 50);
        assertEq(allocator.operation(OPERATION_ID).claimRoot, projection.claimRoot);
        assertEq(LEAF_C, _leafC(projection.operationBinding));
    }

    function test_MutatedProofCannotBeAdmitted() public {
        vm.chainId(1);
        (bytes32 vkey, bytes32 elfSha256, bytes memory publicValues, bytes memory proof, string memory programId) = _readFixture();
        PrfStatementAdmission admission = _deployAdmission(vkey, elfSha256, programId);
        bytes memory mutated = _copy(proof);
        mutated[mutated.length - 1] ^= 0x01;
        vm.expectRevert(PrfStatementAdmission.ProofVerificationFailed.selector);
        admission.admitStatement(VERIFIER_ID, _projection(publicValues).statementRoot, mutated, publicValues);
    }

    function test_MutatedExecutionPublicValuesCannotBeAdmitted() public {
        vm.chainId(1);
        (bytes32 vkey, bytes32 elfSha256, bytes memory publicValues, bytes memory proof, string memory programId) = _readFixture();
        PrfStatementAdmission admission = _deployAdmission(vkey, elfSha256, programId);
        bytes memory mutated = _copy(publicValues);
        mutated[mutated.length - 1] = 0x01;
        vm.expectRevert(PrfStatementAdmission.ProofVerificationFailed.selector);
        admission.admitStatement(VERIFIER_ID, _projection(publicValues).statementRoot, proof, mutated);
    }

    function test_MismatchedAvailableAmountCannotActivate() public {
        vm.chainId(1);
        (bytes32 vkey, bytes32 elfSha256, bytes memory publicValues, bytes memory proof, string memory programId) = _readFixture();
        PrfStatementAdmission admission = _deployAdmission(vkey, elfSha256, programId);
        _etchCommittedContracts(admission);
        EtchedFixtureERC20 token = EtchedFixtureERC20(COMMITTED_TOKEN);
        ProductionProRataAllocatorV1 allocator = ProductionProRataAllocatorV1(COMMITTED_ALLOCATOR);
        token.mint(address(this), 101);
        bytes32 statementRoot = _projection(publicValues).statementRoot;
        allocator.create(OPERATION_ID, statementRoot, CONFIG_ROOT_1, 1, IERC20(COMMITTED_TOKEN), 101, address(0x9999));
        token.approve(COMMITTED_ALLOCATOR, 101);
        allocator.fund(OPERATION_ID);
        bytes32 receiptId = admission.admitStatement(VERIFIER_ID, statementRoot, proof, publicValues);
        vm.expectRevert(ProductionProRataAllocatorV1.ProjectionMismatch.selector);
        allocator.activate(OPERATION_ID, receiptId, publicValues);
    }

    function test_RegistryAdapterVKMismatchRejectsAdmission() public {
        vm.chainId(1); registryVkeyOverride = bytes32(uint256(1));
        (bytes32 vkey, bytes32 elfSha256,, , string memory programId) = _readFixture();
        PrfStatementAdmission admission = _deployAdmission(vkey, elfSha256, programId);
        vm.expectRevert(); admission.admitStatement(VERIFIER_ID, bytes32(uint256(1)), bytes(""), bytes(""));
    }

    function test_RegistryAdapterELFMismatchRejectsAdmission() public {
        vm.chainId(1); registryElfOverride = bytes32(uint256(1));
        (bytes32 vkey, bytes32 elfSha256,, , string memory programId) = _readFixture();
        PrfStatementAdmission admission = _deployAdmission(vkey, elfSha256, programId);
        vm.expectRevert(); admission.admitStatement(VERIFIER_ID, bytes32(uint256(1)), bytes(""), bytes(""));
    }

    function test_RegistryAdapterStatementSchemaMismatchRejectsAdmission() public {
        vm.chainId(1); registryStatementSchemaOverride = bytes32(uint256(1));
        (bytes32 vkey, bytes32 elfSha256,, , string memory programId) = _readFixture();
        PrfStatementAdmission admission = _deployAdmission(vkey, elfSha256, programId);
        vm.expectRevert(); admission.admitStatement(VERIFIER_ID, bytes32(uint256(1)), bytes(""), bytes(""));
    }

    function test_RegistryAdapterPublicValuesSchemaMismatchRejectsAdmission() public {
        vm.chainId(1); registryPublicSchemaOverride = bytes32(uint256(1));
        (bytes32 vkey, bytes32 elfSha256,, , string memory programId) = _readFixture();
        PrfStatementAdmission admission = _deployAdmission(vkey, elfSha256, programId);
        vm.expectRevert(); admission.admitStatement(VERIFIER_ID, bytes32(uint256(1)), bytes(""), bytes(""));
    }

    function test_AdapterRejectsZeroVKey() public {
        SP1Verifier verifier = new SP1Verifier();
        vm.expectRevert(bytes("PREA: zero value"));
        new PrfRealizedExecutionVerifierAdapter(ISP1Verifier(address(verifier)), bytes32(0), bytes32(uint256(1)));
    }

    function test_AdapterRejectsZeroElfSha256() public {
        SP1Verifier verifier = new SP1Verifier();
        vm.expectRevert(bytes("PREA: zero value"));
        new PrfRealizedExecutionVerifierAdapter(ISP1Verifier(address(verifier)), bytes32(uint256(1)), bytes32(0));
    }

    function _readFixture()
        private
        returns (bytes32 vkey, bytes32 elfSha256, bytes memory publicValues, bytes memory proof, string memory programId)
    {
        string memory json = vm.readFile("src/fixtures/realized-execution-proof-fixture.json");
        vkey = abi.decode(vm.parseJson(json, ".vkey"), (bytes32));
        elfSha256 = abi.decode(vm.parseJson(json, ".elfSha256"), (bytes32));
        publicValues = abi.decode(vm.parseJson(json, ".publicValues"), (bytes));
        proof = abi.decode(vm.parseJson(json, ".proof"), (bytes));
        programId = abi.decode(vm.parseJson(json, ".programId"), (string));
    }

    function _deployAdmission(bytes32 vkey, bytes32 elfSha256, string memory programId)
        private
        returns (PrfStatementAdmission admission)
    {
        SewGovernanceAuthorityAdapter authority = new SewGovernanceAuthorityAdapter(
            PROTOCOL_ROOT, address(this), AUTHORITY_STATE_ROOT
        );
        PrfChainInstanceGenesis genesis = new PrfChainInstanceGenesis(
            PROTOCOL_ROOT,
            1,
            1,
            address(authority),
            AUTHORITY_STATE_ROOT,
            CONFIG_ROOT_0,
            address(this)
        );
        genesis.sealGenesis(CHAIN_INSTANCE_ROOT, address(genesis).codehash, address(authority).codehash);

        PrfVerifierRegistry registry = new PrfVerifierRegistry(address(this));
        PrfRealizedExecutionVerifierAdapter adapter = new PrfRealizedExecutionVerifierAdapter(
            ISP1Verifier(address(new SP1Verifier())), vkey, elfSha256
        );

        bytes32 emptyRegistryRoot = _emptyRegistryRoot(registry);
        registry.sealRegistry(emptyRegistryRoot);

        bytes32 registryRoot = _registerAdapter(registry, adapter, vkey, elfSha256, programId);
        SewConfigurationExecutor executor = new SewConfigurationExecutor(genesis, authority, registry, emptyRegistryRoot);
        authority.authoriseDecision(
            DECISION_ROOT,
            executor.TARGET_DIRECT(),
            CHAIN_INSTANCE_ROOT,
            CONFIG_ROOT_0,
            CONFIG_ROOT_1,
            emptyRegistryRoot,
            registryRoot,
            1
        );
        executor.applyConfiguration(
            DECISION_ROOT,
            CONFIG_ROOT_1,
            registryRoot,
            1,
            executor.TARGET_DIRECT(),
            CHAIN_INSTANCE_ROOT,
            new bytes32[](0)
        );
        admission = new PrfStatementAdmission(genesis, executor, registry, CONFIG_ROOT_1, 1);
    }

    function _etchCommittedContracts(PrfStatementAdmission admission) private {
        EtchedFixtureERC20 tokenTemplate = new EtchedFixtureERC20();
        ProductionProRataAllocatorV1 allocatorTemplate = new ProductionProRataAllocatorV1(
            IPrfStatementAdmission(address(admission)), address(this)
        );
        vm.etch(COMMITTED_TOKEN, address(tokenTemplate).code);
        vm.etch(COMMITTED_ALLOCATOR, address(allocatorTemplate).code);
    }

    function _emptyRegistryRoot(PrfVerifierRegistry registry) private pure returns (bytes32) {
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

    function _registerAdapter(
        PrfVerifierRegistry registry,
        PrfRealizedExecutionVerifierAdapter adapter,
        bytes32 vkey,
        bytes32 elfSha256,
        string memory programId
    ) private returns (bytes32 registryRoot) {
        bytes32[] memory ids = new bytes32[](1);
        address[] memory adapters = new address[](1);
        bytes32[] memory vkeys = new bytes32[](1);
        bytes32[] memory elfHashes = new bytes32[](1);
        string[] memory programIds = new string[](1);
        bytes32[] memory statementSchemas = new bytes32[](1);
        bytes32[] memory publicSchemas = new bytes32[](1);
        bool[] memory active = new bool[](1);
        ids[0] = VERIFIER_ID;
        adapters[0] = address(adapter);
        vkeys[0] = registryVkeyOverride == bytes32(0) ? vkey : registryVkeyOverride;
        elfHashes[0] = registryElfOverride == bytes32(0) ? elfSha256 : registryElfOverride;
        programIds[0] = programId;
        statementSchemas[0] = registryStatementSchemaOverride == bytes32(0) ? adapter.statementSchemaVersion() : registryStatementSchemaOverride;
        publicSchemas[0] = registryPublicSchemaOverride == bytes32(0) ? adapter.publicValuesSchema() : registryPublicSchemaOverride;
        active[0] = true;

        registryRoot = registry.computeCanonicalRoot(
            ids, adapters, vkeys, elfHashes, programIds, statementSchemas, publicSchemas, active
        );
        registry.registerVerifier(
            registryRoot,
            VERIFIER_ID,
            address(adapter),
            vkeys[0],
            elfHashes[0],
            programId,
            statementSchemas[0],
            publicSchemas[0]
        );
        registry.sealRegistry(registryRoot);
    }

    function _projection(bytes memory publicValues)
        private
        pure
        returns (PrfRealizedExecutionVerifierAdapter.ExecutionPublicValues memory)
    {
        return abi.decode(publicValues, (PrfRealizedExecutionVerifierAdapter.ExecutionPublicValues));
    }

    function _copy(bytes memory data) private pure returns (bytes memory copied) {
        copied = new bytes(data.length);
        for (uint256 i; i < data.length; ++i) copied[i] = data[i];
    }

    function _binding() private view returns (bytes32) {
        return keccak256(abi.encode(
            keccak256("prf.realized-allocation-execution.operation-binding.v1"),
            block.chainid,
            COMMITTED_ALLOCATOR,
            COMMITTED_TOKEN,
            OPERATION_ID,
            uint256(100)
        ));
    }

    function _leafC(bytes32 binding) private pure returns (bytes32) {
        return _leaf(binding, "C", address(0x3333333333333333333333333333333333333333), 20);
    }

    function _leaf(bytes32 binding, string memory claimId, address recipient, uint256 amount)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(
            keccak256("prf.realized-allocation-execution.claim-leaf.v1"),
            binding,
            keccak256(bytes(claimId)),
            recipient,
            amount
        ));
    }

    function _node(bytes32 left, bytes32 right) private pure returns (bytes32) {
        return keccak256(abi.encode(keccak256("prf.realized-allocation-execution.claim-node.v1"), left, right));
    }
}
