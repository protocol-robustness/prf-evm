// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ISP1Verifier} from "../src/verification/interfaces/ISP1Verifier.sol";
import {PrfSourceBoundStatementVerifierAdapterV2} from "../src/verification/adapters/PrfSourceBoundStatementVerifierAdapterV2.sol";
import {ShortfallV2Commitments} from "../src/verification/ShortfallV2Commitments.sol";

contract V2MockSP1Verifier is ISP1Verifier {
    function verifyProof(bytes32, bytes calldata, bytes calldata) external pure {}
}

contract PrfSourceBoundStatementVerifierAdapterV2Test is Test {
    V2MockSP1Verifier verifier;
    PrfSourceBoundStatementVerifierAdapterV2 adapter;
    bytes32 constant VKEY = keccak256("v2-vkey");
    bytes32 constant ELF = keccak256("v2-elf");
    bytes32 constant STATEMENT = keccak256("statement");
    bytes32 constant OPERATION = keccak256("operation");

    function setUp() public {
        verifier = new V2MockSP1Verifier();
        adapter = new PrfSourceBoundStatementVerifierAdapterV2(verifier, VKEY, ELF);
    }

    function test_DecodesExactlySixV2Words() public {
        bytes memory values = _values(OPERATION);
        PrfSourceBoundStatementVerifierAdapterV2.SourceBoundPublicValuesV2 memory decoded = adapter.decodePublicValues(values);
        assertEq(decoded.schema, adapter.PUBLIC_VALUES_DOMAIN());
        assertEq(decoded.operationId, OPERATION);
        assertEq(values.length, 192);
    }

    function test_RustGoldenVectorCommitmentsAndPublicValuesMatch() public {
        ShortfallV2Commitments.PreparedOperation memory prepared = ShortfallV2Commitments.PreparedOperation({
            operationId: _word(1), initiator: _word(2), chainId: 31337, reserve: _word(3), token: _word(4), allocator: _word(5),
            configurationRoot: _word(6), configurationEpoch: 7, sourceVerifierId: _word(8), executionVerifierId: _word(9),
            sourceProgramVKey: _word(10), sourceProgramElfSha256: _word(11), sourceStatementSchema: _word(12),
            sourcePublicValuesSchema: _word(13), executionStatementSchema: _word(14), executionPublicValuesSchema: _word(15),
            policyRoot: _word(16), residualRecipient: _word(17)
        });
        bytes32 preparedRoot = ShortfallV2Commitments.preparedOperationRoot(prepared);
        assertEq(preparedRoot, hex"9a66110648a9eacae606759eef7844a13b51ae43c591b36a4a151d0e02df43b4");
        ShortfallV2Commitments.EconomicReserveState memory state = ShortfallV2Commitments.EconomicReserveState({
            preparedOperationRoot: preparedRoot, reserve: _word(3), token: _word(4), grossBalance: 100,
            reservedBefore: 20, protectedCapital: 10, availableAmount: 70, availabilityRevision: 17
        });
        bytes32 commitment = ShortfallV2Commitments.reserveStateCommitment(state);
        assertEq(commitment, hex"e57f2af51e6c16fd0285c44ff2c99963819c6f5559d5b979de7c9c50026114ac");
        assertEq(_valuesFromRoots(preparedRoot, commitment, _word(1)), hex"a069c379e311996c73ea1f69edb070bfddbb573b770b3c5aec52bad4b255aa879a66110648a9eacae606759eef7844a13b51ae43c591b36a4a151d0e02df43b4e57f2af51e6c16fd0285c44ff2c99963819c6f5559d5b979de7c9c50026114ac121212121212121212121212121212121212121212121212121212121212121213131313131313131313131313131313131313131313131313131313131313130101010101010101010101010101010101010101010101010101010101010101");
    }

    function test_GeneratedV2ProofFixtureDecodes() public {
        bytes memory publicValues = abi.encode(
            adapter.PUBLIC_VALUES_DOMAIN(),
            bytes32(hex"35d44679111c6e528f4f3ff31f7ad1a1e87c89d5ef65369d059128e942ca22ee"),
            bytes32(hex"c8dccbd63ccfb5044aad555dc6a3ecdd4b688ddaac6ba57b5c9af1e8b45ca3e7"),
            bytes32(hex"0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a"),
            bytes32(hex"000b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"),
            bytes32(hex"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
        PrfSourceBoundStatementVerifierAdapterV2.SourceBoundPublicValuesV2 memory values = adapter.decodePublicValues(publicValues);
        assertEq(values.preparedOperationRoot, hex"35d44679111c6e528f4f3ff31f7ad1a1e87c89d5ef65369d059128e942ca22ee");
        assertEq(values.reserveStateCommitment, hex"c8dccbd63ccfb5044aad555dc6a3ecdd4b688ddaac6ba57b5c9af1e8b45ca3e7");
        assertEq(values.operationId, hex"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    }

    function test_V1WidthIsRejected() public {
        vm.expectRevert(abi.encodeWithSelector(
            PrfSourceBoundStatementVerifierAdapterV2.InvalidPublicValuesLength.selector, 160));
        adapter.decodePublicValues(new bytes(160));
    }


    function _values(bytes32 operationId) internal view returns (bytes memory) {
        return abi.encode(adapter.PUBLIC_VALUES_DOMAIN(), keccak256("prepared"), keccak256("economic"), keccak256("allocation"), keccak256("realized"), operationId);
    }

    function _valuesFromRoots(bytes32 prepared, bytes32 commitment, bytes32 operationId) internal view returns (bytes memory) {
        return abi.encode(adapter.PUBLIC_VALUES_DOMAIN(), prepared, commitment, _word(18), _word(19), operationId);
    }

    function _word(uint8 n) internal pure returns (bytes32) { return bytes32(uint256(n) * 0x0101010101010101010101010101010101010101010101010101010101010101); }
}
