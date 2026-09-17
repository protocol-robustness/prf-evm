// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {PrfStatementAdmissionTest} from "./PrfStatementAdmission.t.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPrfStatementAdmission} from "../src/interfaces/IPrfStatementAdmission.sol";
import {ISP1Verifier} from "../src/ISP1Verifier.sol";
import {MockSP1Verifier} from "../src/MockSP1Verifier.sol";
import {PrfRealizedExecutionVerifierAdapter} from "../src/PrfRealizedExecutionVerifierAdapter.sol";
import {PrfVerifierRegistry} from "../src/PrfVerifierRegistry.sol";
import {SewConfigurationExecutor} from "../src/SewConfigurationExecutor.sol";
import {PrfStatementAdmission} from "../src/PrfStatementAdmission.sol";
import {ProductionProRataAllocatorV1} from "../src/ProductionProRataAllocatorV1.sol";

contract IntegrationToken is ERC20 {
    constructor() ERC20("Integration", "INT") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @notice Exercises the generic registry/admission boundary, not a synthetic receipt store.
contract ProductionProRataAllocatorV1AdmissionIntegrationTest is PrfStatementAdmissionTest {
    bytes32 private constant EXECUTION_VERIFIER_ID = keccak256("realized-allocation-execution.v1");
    bytes32 private constant EXECUTION_VKEY = keccak256("execution-vkey");
    bytes32 private constant EXECUTION_ELF = keccak256("execution-elf");
    bytes32 private constant OPERATION_ID = keccak256("admission-integrated-operation");
    bytes32 private constant BINDING_DOMAIN = keccak256("prf.realized-allocation-execution.operation-binding.v1");
    bytes32 private constant LEAF_DOMAIN = keccak256("prf.realized-allocation-execution.claim-leaf.v1");

    function test_ActualGenericAdmissionReceiptActivatesAllocator() public {
        IntegrationToken token = new IntegrationToken();
        token.mint(address(this), 100);

        uint64 nonce = vm.getNonce(address(this));
        address predictedMock = _createAddress(address(this), nonce + 1);
        address predictedAdapter = _createAddress(address(this), nonce + 2);
        address predictedExecutor = _createAddress(address(this), nonce + 3);
        address predictedAdmission = _createAddress(address(this), nonce + 4);
        address predictedAllocator = _createAddress(address(this), nonce + 5);

        bytes32 binding = keccak256(abi.encode(
            BINDING_DOMAIN, block.chainid, predictedAllocator, address(token), OPERATION_ID, uint256(100)
        ));
        bytes32 claimRoot = keccak256(abi.encode(
            LEAF_DOMAIN, binding, keccak256(bytes("A")), address(0x1111), uint256(100)
        ));
        bytes memory publicValues = abi.encode(
            keccak256("realized-allocation-execution-public-values.v1"),
            FIXTURE_STATEMENT_ROOT, binding, claimRoot, address(token), predictedAllocator,
            block.chainid, OPERATION_ID, 100, 1, 100, 0
        );

        PrfVerifierRegistry executionRegistry = new PrfVerifierRegistry(address(this));
        assertEq(address(executionRegistry), _createAddress(address(this), nonce));
        MockSP1Verifier mock = new MockSP1Verifier(
            keccak256(abi.encodePacked(bytes(""), EXECUTION_VKEY, publicValues)), VERIFIER_HASH
        );
        assertEq(address(mock), predictedMock);
        PrfRealizedExecutionVerifierAdapter executionAdapter = new PrfRealizedExecutionVerifierAdapter(
            ISP1Verifier(address(mock)), EXECUTION_VKEY, EXECUTION_ELF
        );
        assertEq(address(executionAdapter), predictedAdapter);

        bytes32 registryRoot = _registerExecutionAdapter(executionRegistry, executionAdapter);
        SewConfigurationExecutor executionExecutor = new SewConfigurationExecutor(
            genesis, authority, executionRegistry, registryRoot
        );
        assertEq(address(executionExecutor), predictedExecutor);
        PrfStatementAdmission executionAdmission = new PrfStatementAdmission(
            genesis, executionExecutor, executionRegistry, CONFIG_ROOT_0, 0
        );
        assertEq(address(executionAdmission), predictedAdmission);
        ProductionProRataAllocatorV1 allocator = new ProductionProRataAllocatorV1(
            IPrfStatementAdmission(address(executionAdmission)), address(this)
        );
        assertEq(address(allocator), predictedAllocator);

        allocator.create(OPERATION_ID, FIXTURE_STATEMENT_ROOT, CONFIG_ROOT_0, 0, token, 100, address(0x9999));
        token.approve(address(allocator), 100);
        allocator.fund(OPERATION_ID);
        bytes32 receiptId = executionAdmission.admitStatement(
            EXECUTION_VERIFIER_ID, FIXTURE_STATEMENT_ROOT, bytes(""), publicValues
        );
        allocator.activate(OPERATION_ID, receiptId, publicValues);

        assertEq(uint256(allocator.operation(OPERATION_ID).state), uint256(ProductionProRataAllocatorV1.State.Activated));
        assertEq(executionAdmission.admissionReceipt(receiptId).verifierAdapter, address(executionAdapter));
    }

    function _createAddress(address creator, uint64 nonce) private pure returns (address) {
        require(nonce < 128, "test nonce too large");
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", creator, bytes1(uint8(nonce)))))));
    }

    function _registerExecutionAdapter(PrfVerifierRegistry executionRegistry, PrfRealizedExecutionVerifierAdapter adapter)
        private returns (bytes32 root)
    {
        bytes32[] memory ids = new bytes32[](1); ids[0] = EXECUTION_VERIFIER_ID;
        address[] memory adapters = new address[](1); adapters[0] = address(adapter);
        bytes32[] memory vkeys = new bytes32[](1); vkeys[0] = EXECUTION_VKEY;
        bytes32[] memory elfs = new bytes32[](1); elfs[0] = EXECUTION_ELF;
        string[] memory programIds = new string[](1); programIds[0] = "realized-execution-sp1-program.v1";
        bytes32[] memory statementSchemas = new bytes32[](1); statementSchemas[0] = adapter.statementSchemaVersion();
        bytes32[] memory publicSchemas = new bytes32[](1); publicSchemas[0] = adapter.publicValuesSchema();
        bool[] memory active = new bool[](1); active[0] = true;
        root = executionRegistry.computeCanonicalRoot(ids, adapters, vkeys, elfs, programIds, statementSchemas, publicSchemas, active);
        executionRegistry.registerVerifier(root, EXECUTION_VERIFIER_ID, address(adapter), EXECUTION_VKEY, EXECUTION_ELF,
            programIds[0], statementSchemas[0], publicSchemas[0]);
        executionRegistry.sealRegistry(root);
    }
}
