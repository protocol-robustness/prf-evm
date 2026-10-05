// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {SP1Verifier} from "@sp1-contracts/v6.1.0/SP1VerifierGroth16.sol";
import {PrfChainInstanceGenesis} from "../src/core/PrfChainInstanceGenesis.sol";
import {SewGovernanceAuthorityAdapter} from "../src/integrations/sew/SewGovernanceAuthorityAdapter.sol";
import {SewConfigurationExecutor} from "../src/integrations/sew/SewConfigurationExecutor.sol";
import {PrfVerifierRegistry} from "../src/core/PrfVerifierRegistry.sol";
import {PrfStatementAdmission} from "../src/core/PrfStatementAdmission.sol";
import {
    PrfSourceBoundEntitlementVerifierAdapterV1
} from "../src/verification/adapters/PrfSourceBoundEntitlementVerifierAdapterV1.sol";
import {IPrfStatementAdmission} from "../src/interfaces/IPrfStatementAdmission.sol";
import {IPrfVerifierRegistry} from "../src/interfaces/IPrfVerifierRegistry.sol";
import {ISP1Verifier} from "../src/verification/interfaces/ISP1Verifier.sol";

contract PrfSourceBoundEntitlementAdmissionRealProofTest is Test {
    bytes32 private constant PROTOCOL_ROOT = keccak256("b4-entitlement-admission-protocol");
    bytes32 private constant AUTHORITY_ROOT = keccak256("b4-entitlement-admission-authority");
    bytes32 private constant CHAIN_INSTANCE_ROOT = keccak256("b4-entitlement-admission-chain");
    bytes32 private constant CONFIG_ROOT = keccak256("b4-entitlement-admission-config");
    bytes32 private constant VERIFIER_ID = keccak256("source-bound-entitlement-sp1-program.v1");
    bytes32 private constant VKEY = 0x003cb0ac41d9c5cd78fe461b5ba27dfb08cd74490c9526fa762e7e392ee7bac5;
    bytes32 private constant ELF_SHA256 = 0x7e9cf1b3479a4b6fb8836b50b30b55d00736ac860eaba4230f057d4687bc0e39;
    bytes32 private constant PV_SCHEMA = keccak256("prf/source-bound-entitlement-public-values.v1");
    bytes32 private constant STATEMENT_SCHEMA = keccak256("prf/onchain-shortfall-allocation-binding.v1");

    function test_RealB3Groth16ProofAdmittedAndReceiptBindsProfile() public {
        string memory fixture = vm.readFile("test/fixtures/source-bound-entitlement-v1-proof-fixture.json");
        assertEq(abi.decode(vm.parseJson(fixture, ".proof_system"), (string)), "groth16");
        assertEq(abi.decode(vm.parseJson(fixture, ".vkey"), (bytes32)), VKEY);
        assertEq(abi.decode(vm.parseJson(fixture, ".elf_sha256"), (bytes32)), ELF_SHA256);
        bytes memory proof = abi.decode(vm.parseJson(fixture, ".proof"), (bytes));
        bytes memory publicValues = abi.decode(vm.parseJson(fixture, ".public_values"), (bytes));
        assertEq(publicValues.length, 288);

        (,,, bytes32 statementRoot,,,,,) =
            abi.decode(publicValues, (bytes32, bytes32, bytes32, bytes32, bytes32, bytes32, uint256, uint256, bytes32));

        SewGovernanceAuthorityAdapter authority =
            new SewGovernanceAuthorityAdapter(PROTOCOL_ROOT, address(this), AUTHORITY_ROOT);
        PrfChainInstanceGenesis genesis = new PrfChainInstanceGenesis(
            PROTOCOL_ROOT, block.chainid, 1, address(authority), AUTHORITY_ROOT, CONFIG_ROOT, address(this)
        );
        genesis.sealGenesis(CHAIN_INSTANCE_ROOT, address(genesis).codehash, address(authority).codehash);

        PrfVerifierRegistry registry = new PrfVerifierRegistry(address(this));
        SP1Verifier sp1Verifier = new SP1Verifier();
        PrfSourceBoundEntitlementVerifierAdapterV1 adapter =
            new PrfSourceBoundEntitlementVerifierAdapterV1(ISP1Verifier(address(sp1Verifier)), VKEY, ELF_SHA256);

        bytes32[] memory ids = new bytes32[](1);
        address[] memory adapters = new address[](1);
        bytes32[] memory vkeys = new bytes32[](1);
        bytes32[] memory elfHashes = new bytes32[](1);
        string[] memory programIds = new string[](1);
        bytes32[] memory statementSchemas = new bytes32[](1);
        bytes32[] memory publicValueSchemas = new bytes32[](1);
        bool[] memory active = new bool[](1);
        ids[0] = VERIFIER_ID;
        adapters[0] = address(adapter);
        vkeys[0] = VKEY;
        elfHashes[0] = ELF_SHA256;
        programIds[0] = "source-bound-entitlement-sp1-program.v1";
        statementSchemas[0] = STATEMENT_SCHEMA;
        publicValueSchemas[0] = PV_SCHEMA;
        active[0] = true;

        bytes32 registryRoot = registry.computeCanonicalRoot(
            ids, adapters, vkeys, elfHashes, programIds, statementSchemas, publicValueSchemas, active
        );
        registry.registerVerifier(
            registryRoot,
            VERIFIER_ID,
            address(adapter),
            VKEY,
            ELF_SHA256,
            "source-bound-entitlement-sp1-program.v1",
            STATEMENT_SCHEMA,
            PV_SCHEMA
        );
        registry.sealRegistry(registryRoot);

        SewConfigurationExecutor executor = new SewConfigurationExecutor(genesis, authority, registry, registryRoot);
        PrfStatementAdmission admission = new PrfStatementAdmission(genesis, executor, registry, CONFIG_ROOT, 0);

        bytes32 receiptId = admission.admitStatement(VERIFIER_ID, statementRoot, proof, publicValues);
        assertTrue(receiptId != bytes32(0));
        IPrfStatementAdmission.AdmissionReceipt memory receipt = admission.admissionReceipt(receiptId);
        assertTrue(receipt.exists);
        assertEq(receipt.protocolGenesisRoot, PROTOCOL_ROOT);
        assertEq(receipt.chainInstanceGenesisRoot, CHAIN_INSTANCE_ROOT);
        assertEq(receipt.configurationRoot, CONFIG_ROOT);
        assertEq(receipt.configurationEpoch, 0);
        assertEq(receipt.verifierRegistryRoot, registryRoot);
        assertEq(receipt.verifierId, VERIFIER_ID);
        assertEq(receipt.verifierAdapter, address(adapter));
        assertEq(receipt.programVKey, VKEY);
        assertEq(receipt.programElfSha256, ELF_SHA256);
        assertEq(receipt.statementSchemaVersionHash, STATEMENT_SCHEMA);
        assertEq(receipt.publicValuesSchema, PV_SCHEMA);
        assertEq(receipt.statementRoot, statementRoot);
        assertEq(receipt.publicValuesDigest, sha256(publicValues));
        assertEq(admission.admittedCount(), 1);

        // Every semantic public word after the schema is proof-bound. Altering
        // any one word while preserving the statement argument must fail admission.
        for (uint256 wordIndex = 1; wordIndex < 9; ++wordIndex) {
            bytes memory tampered = _replaceWord(publicValues, wordIndex, bytes32(uint256(0xdead) + wordIndex));
            vm.expectRevert();
            admission.admitStatement(VERIFIER_ID, statementRoot, proof, tampered);
        }

        vm.expectRevert();
        admission.admitStatement(bytes32(uint256(0xBAD)), statementRoot, proof, publicValues);

        PrfStatementAdmission wrongConfigurationAdmission =
            new PrfStatementAdmission(genesis, executor, registry, keccak256("wrong-configuration"), 0);
        vm.expectRevert();
        wrongConfigurationAdmission.admitStatement(VERIFIER_ID, statementRoot, proof, publicValues);
    }

    function _replaceWord(bytes memory source, uint256 wordIndex, bytes32 value)
        private
        pure
        returns (bytes memory result)
    {
        result = new bytes(source.length);
        for (uint256 i; i < source.length; ++i) {
            result[i] = source[i];
        }
        assembly ("memory-safe") {
            mstore(add(add(result, 0x20), mul(wordIndex, 0x20)), value)
        }
    }
}
