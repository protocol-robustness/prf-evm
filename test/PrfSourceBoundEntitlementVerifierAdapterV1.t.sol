// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {SP1Verifier} from "@sp1-contracts/v6.1.0/SP1VerifierGroth16.sol";
import {ISP1Verifier} from "../src/verification/interfaces/ISP1Verifier.sol";
import {
    PrfSourceBoundEntitlementVerifierAdapterV1
} from "../src/verification/adapters/PrfSourceBoundEntitlementVerifierAdapterV1.sol";

contract EntitlementMockSP1Verifier is ISP1Verifier {
    function verifyProof(bytes32, bytes calldata, bytes calldata) external pure {}
}

contract PrfSourceBoundEntitlementVerifierAdapterV1Test is Test {
    EntitlementMockSP1Verifier internal verifier;
    PrfSourceBoundEntitlementVerifierAdapterV1 internal adapter;

    bytes32 internal constant SCHEMA = 0x876f2aea9124d79f41dbdd389d498430987fa33bbb34408989849c478a7c2bde;
    bytes32 internal constant DESCRIPTOR = 0x0e8b6d0eb8a46279fee6697366b2bdfa0b4aa514dacf17e9e264744d90d91c1f;

    function setUp() public {
        verifier = new EntitlementMockSP1Verifier();
        adapter = new PrfSourceBoundEntitlementVerifierAdapterV1(
            verifier, keccak256("entitlement-vkey"), keccak256("entitlement-elf")
        );
    }

    function test_DecodesExactNineWordProfileAndOffsets() public {
        bytes memory encoded = _values(SCHEMA, DESCRIPTOR, bytes32(uint256(4)));
        PrfSourceBoundEntitlementVerifierAdapterV1.SourceBoundEntitlementPublicValuesV1 memory values =
            adapter.decodePublicValues(encoded);

        assertEq(encoded.length, 288);
        assertEq(values.schema, SCHEMA);
        assertEq(values.preparedOperationRoot, bytes32(uint256(1)));
        assertEq(values.reserveStateCommitment, bytes32(uint256(2)));
        assertEq(values.allocationBindingRoot, bytes32(uint256(3)));
        assertEq(values.entitlementRepresentationDescriptorRoot, DESCRIPTOR);
        assertEq(values.evmEntitlementTableRoot, bytes32(uint256(5)));
        assertEq(values.entitlementCount, 3);
        assertEq(values.entitlementTotal, 70);
        assertEq(values.allocationClaimRoot, bytes32(uint256(4)));
        assertEq(abi.encode(values), encoded);
    }

    function test_SchemaConstantMatchesFrozenProfileIdentifier() public {
        assertEq(adapter.PUBLIC_VALUES_SCHEMA(), SCHEMA);
        assertEq(adapter.publicValuesSchema(), SCHEMA);
        assertEq(adapter.statementSchemaVersion(), keccak256("prf/onchain-shortfall-allocation-binding.v1"));
    }

    function test_RejectsShortAndTrailingPublicValues() public {
        bytes memory encoded = _values(SCHEMA, DESCRIPTOR, bytes32(uint256(4)));
        vm.expectRevert(
            abi.encodeWithSelector(PrfSourceBoundEntitlementVerifierAdapterV1.InvalidPublicValuesLength.selector, 287)
        );
        adapter.decodePublicValues(_slice(encoded, 287));

        vm.expectRevert(
            abi.encodeWithSelector(PrfSourceBoundEntitlementVerifierAdapterV1.InvalidPublicValuesLength.selector, 289)
        );
        adapter.decodePublicValues(bytes.concat(encoded, hex"00"));
    }

    function test_RejectsHistorical192ByteAndUnrelated384ByteProfiles() public {
        bytes memory historical = new bytes(192);
        bytes memory unrelated = new bytes(384);
        vm.expectRevert(
            abi.encodeWithSelector(PrfSourceBoundEntitlementVerifierAdapterV1.InvalidPublicValuesLength.selector, 192)
        );
        adapter.decodePublicValues(historical);
        vm.expectRevert(
            abi.encodeWithSelector(PrfSourceBoundEntitlementVerifierAdapterV1.InvalidPublicValuesLength.selector, 384)
        );
        adapter.decodePublicValues(unrelated);
    }

    function test_RejectsWrongSchemaAndDescriptor() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                PrfSourceBoundEntitlementVerifierAdapterV1.PublicValuesSchemaMismatch.selector, bytes32(uint256(99))
            )
        );
        adapter.decodePublicValues(_values(bytes32(uint256(99)), DESCRIPTOR, bytes32(uint256(4))));

        vm.expectRevert(
            abi.encodeWithSelector(
                PrfSourceBoundEntitlementVerifierAdapterV1.DescriptorRootMismatch.selector,
                DESCRIPTOR,
                bytes32(uint256(99))
            )
        );
        adapter.decodePublicValues(_values(SCHEMA, bytes32(uint256(99)), bytes32(uint256(4))));
    }

    function test_VerificationBindsAdmissionStatementToAllocationBindingRoot() public {
        bytes memory encoded = _values(SCHEMA, DESCRIPTOR, bytes32(uint256(4)));
        assertEq(adapter.verifyStatementProof(bytes32(uint256(3)), hex"01", encoded), bytes32(uint256(3)));
        vm.expectRevert(
            abi.encodeWithSelector(
                PrfSourceBoundEntitlementVerifierAdapterV1.StatementRootMismatch.selector,
                bytes32(uint256(8)),
                bytes32(uint256(3))
            )
        );
        adapter.verifyStatementProof(bytes32(uint256(8)), hex"01", encoded);
    }

    function test_RealB3Groth16FixtureVerifies() public {
        string memory fixturePath = "test/fixtures/source-bound-entitlement-v1-proof-fixture.json";
        string memory fixture = vm.readFile(fixturePath);
        assertEq(abi.decode(vm.parseJson(fixture, ".program_id"), (string)), "source-bound-entitlement-sp1-program.v1");
        assertEq(abi.decode(vm.parseJson(fixture, ".proof_system"), (string)), "groth16");
        assertEq(
            abi.decode(vm.parseJson(fixture, ".vkey"), (bytes32)),
            0x003cb0ac41d9c5cd78fe461b5ba27dfb08cd74490c9526fa762e7e392ee7bac5
        );
        assertEq(
            abi.decode(vm.parseJson(fixture, ".elf_sha256"), (bytes32)),
            0x7e9cf1b3479a4b6fb8836b50b30b55d00736ac860eaba4230f057d4687bc0e39
        );
        bytes memory proof = abi.decode(vm.parseJson(fixture, ".proof"), (bytes));
        bytes memory publicValues = abi.decode(vm.parseJson(fixture, ".public_values"), (bytes));
        assertEq(publicValues.length, 288);

        SP1Verifier groth16 = new SP1Verifier();
        PrfSourceBoundEntitlementVerifierAdapterV1 realAdapter = new PrfSourceBoundEntitlementVerifierAdapterV1(
            ISP1Verifier(address(groth16)),
            0x003cb0ac41d9c5cd78fe461b5ba27dfb08cd74490c9526fa762e7e392ee7bac5,
            0x7e9cf1b3479a4b6fb8836b50b30b55d00736ac860eaba4230f057d4687bc0e39
        );
        PrfSourceBoundEntitlementVerifierAdapterV1.SourceBoundEntitlementPublicValuesV1 memory values =
            realAdapter.decodePublicValues(publicValues);
        assertEq(
            realAdapter.verifyStatementProof(values.allocationBindingRoot, proof, publicValues),
            values.allocationBindingRoot
        );
        assertEq(values.entitlementCount, 3);
        assertEq(values.entitlementTotal, 70);

        PrfSourceBoundEntitlementVerifierAdapterV1 wrongVkeyAdapter = new PrfSourceBoundEntitlementVerifierAdapterV1(
            ISP1Verifier(address(groth16)),
            bytes32(uint256(adapter.programVKey()) ^ 1),
            0x7e9cf1b3479a4b6fb8836b50b30b55d00736ac860eaba4230f057d4687bc0e39
        );
        vm.expectRevert();
        wrongVkeyAdapter.verifyStatementProof(values.allocationBindingRoot, proof, publicValues);

        bytes memory wrongProof = bytes.concat(proof);
        wrongProof[0] = bytes1(uint8(wrongProof[0]) ^ 1);
        vm.expectRevert();
        realAdapter.verifyStatementProof(values.allocationBindingRoot, wrongProof, publicValues);
    }

    function _values(bytes32 schema, bytes32 descriptor, bytes32 claimRoot) internal pure returns (bytes memory) {
        return abi.encode(
            schema,
            bytes32(uint256(1)),
            bytes32(uint256(2)),
            bytes32(uint256(3)),
            descriptor,
            bytes32(uint256(5)),
            uint256(3),
            uint256(70),
            claimRoot
        );
    }

    function _slice(bytes memory data, uint256 length) internal pure returns (bytes memory result) {
        result = new bytes(length);
        for (uint256 i; i < length; ++i) {
            result[i] = data[i];
        }
    }
}
