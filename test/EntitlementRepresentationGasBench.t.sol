// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IEntitlementRepresentationV1} from "../src/interfaces/IEntitlementRepresentationV1.sol";
import {IShortfallAllocatorV2} from "../src/interfaces/IShortfallAllocatorV2.sol";
import {MockEntitlementProofModeSource} from "./mocks/MockEntitlementProofModeSource.sol";
import {ProductionProRataAllocatorV2} from "../src/applications/pro-rata/ProductionProRataAllocatorV2.sol";
import {
    PublicPackedEntitlementRepresentationV1
} from "../src/applications/pro-rata/PublicPackedEntitlementRepresentationV1.sol";
import {
    CommittedImmutableEntitlementRepresentationV1
} from "../src/applications/pro-rata/CommittedImmutableEntitlementRepresentationV1.sol";

contract EntitlementGasToken is ERC20 {
    constructor() ERC20("Entitlement Gas", "EGAS") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Reproducible local-EVM measurements; not a Base cost estimate.
contract EntitlementRepresentationGasBench is Test {
    bytes32 private constant BINDING = keccak256("representation-gas-benchmark-binding");
    bytes32 private constant PROFILE = keccak256("smart-account-v1");
    bytes32 private constant COMMITMENT_DOMAIN = keccak256("prf.source-bound-entitlement.commitment.v1");
    bytes32 private constant TABLE_NODE_DOMAIN = keccak256("prf.source-bound-entitlement.table-node.v1");
    bytes32 private constant CLAIM_LEAF_DOMAIN = keccak256("prf.source-bound-entitlement.claim-leaf.v1");

    function test_Benchmark_10() public {
        _benchmark(10);
    }

    function test_Benchmark_100() public {
        _benchmark(100);
    }

    function test_Benchmark_1000() public {
        _benchmark(1_000);
    }

    function test_Benchmark_10000() public {
        _benchmark(10_000);
    }

    function _benchmark(uint256 count) private {
        bytes32 operationId = keccak256(abi.encode("representation-gas-operation", count));
        uint256 total = count;
        bytes32[] memory commitments = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            (bytes memory claim, address beneficiary, bytes32 salt, bytes32 claimHash) = _member(i);
            claim;
            commitments[i] = keccak256(
                abi.encode(
                    COMMITMENT_DOMAIN, BINDING, operationId, i, claimHash, beneficiary, uint256(1), PROFILE, salt
                )
            );
        }

        uint256 beforeDeploy = gasleft();
        PublicPackedEntitlementRepresentationV1 packed = new PublicPackedEntitlementRepresentationV1(commitments, total);
        uint256 packedDeploymentGas = beforeDeploy - gasleft();

        beforeDeploy = gasleft();
        CommittedImmutableEntitlementRepresentationV1 committed =
            new CommittedImmutableEntitlementRepresentationV1(commitments, total, 256);
        uint256 committedDeploymentGas = beforeDeploy - gasleft();
        assertEq(committed.logicalRoot(), packed.logicalRoot(), "logical root differs by representation");
        assertEq(committed.entitlementCount(), count);
        assertEq(committed.entitlementTotal(), total);

        uint256 shardCount = committed.physicalShardCount();
        uint256 packedRuntimeBytes = address(packed).code.length;
        uint256 committedRuntimeBytes = address(committed).code.length;
        uint256 immutableShardCodeBytes = 32 * count + shardCount;

        console2.log("BENCH_SIZE", count);
        console2.log("BENCH_PACKED_DEPLOY_GAS", packedDeploymentGas);
        console2.log("BENCH_IMMUTABLE_DEPLOY_GAS", committedDeploymentGas);
        console2.log("BENCH_PACKED_STORAGE_WORDS", count + 1);
        console2.log("BENCH_IMMUTABLE_POINTER_STORAGE_WORDS", shardCount + 1);
        console2.log("BENCH_PACKED_RUNTIME_CODE_BYTES", packedRuntimeBytes);
        console2.log("BENCH_IMMUTABLE_WRAPPER_RUNTIME_BYTES", committedRuntimeBytes);
        console2.log("BENCH_IMMUTABLE_SHARD_CODE_BYTES", immutableShardCodeBytes);
        console2.log("BENCH_IMMUTABLE_PHYSICAL_SHARDS", shardCount);

        _benchmarkRequestedWithdrawals(count, operationId, commitments, committed);
    }

    function _benchmarkRequestedWithdrawals(
        uint256 count,
        bytes32 operationId,
        bytes32[] memory commitments,
        CommittedImmutableEntitlementRepresentationV1 representation
    ) private {
        (, bytes32[] memory tablePath0, bytes32[] memory tablePath1) =
            _rootAndFirstTwoPaths(commitments, TABLE_NODE_DOMAIN);
        EntitlementGasToken token = new EntitlementGasToken();
        ProductionProRataAllocatorV2 allocator =
            new ProductionProRataAllocatorV2(address(this), new MockEntitlementProofModeSource());
        token.mint(address(this), count);
        token.approve(address(allocator), count);
        allocator.createEntitlement(
            operationId,
            BINDING,
            keccak256("committed-immutable-table-v1 descriptor"),
            representation.logicalRoot(),
            count,
            count,
            keccak256("benchmark-claim-root"),
            PROFILE,
            token,
            count,
            address(0xD00D)
        );
        allocator.fundEntitlement(operationId);
        allocator.activateEntitlement(operationId, IEntitlementRepresentationV1(address(representation)));

        (bytes memory claim0, address beneficiary0, bytes32 salt0,) = _member(0);
        uint256 beforeWithdraw = gasleft();
        allocator.withdraw(
            operationId,
            ProductionProRataAllocatorV2.EntitlementOpening(0, claim0, beneficiary0, 1, salt0),
            tablePath0,
            false,
            new bytes32[](0),
            ProductionProRataAllocatorV2.ProofMode.Requested
        );
        uint256 firstBitmapWordWithdrawalGas = beforeWithdraw - gasleft();

        (bytes memory claim1, address beneficiary1, bytes32 salt1,) = _member(1);
        beforeWithdraw = gasleft();
        allocator.withdraw(
            operationId,
            ProductionProRataAllocatorV2.EntitlementOpening(1, claim1, beneficiary1, 1, salt1),
            tablePath1,
            false,
            new bytes32[](0),
            ProductionProRataAllocatorV2.ProofMode.Requested
        );
        uint256 additionalBitSameWordWithdrawalGas = beforeWithdraw - gasleft();

        assertTrue(allocator.consumed(operationId, 0));
        assertTrue(allocator.consumed(operationId, 1));
        assertEq(allocator.outstandingLiability(operationId), count - 2);
        console2.log("BENCH_TABLE_PROOF_DEPTH", tablePath0.length);
        console2.log("BENCH_REQUESTED_WITHDRAW_FIRST_BITMAP_WORD_GAS", firstBitmapWordWithdrawalGas);
        console2.log("BENCH_REQUESTED_WITHDRAW_SAME_WORD_ADDITIONAL_BIT_GAS", additionalBitSameWordWithdrawalGas);
    }

    function _member(uint256 index)
        private
        pure
        returns (bytes memory claim, address beneficiary, bytes32 salt, bytes32 claimHash)
    {
        claim = bytes.concat(bytes("claim-"), bytes(_decimal(index)));
        beneficiary = address(uint160(0x10000 + index));
        salt = bytes32(index + 1);
        claimHash = keccak256(abi.encodePacked(bytes1(0x20), bytes1(uint8(claim.length)), claim));
    }

    function _rootAndFirstTwoPaths(bytes32[] memory leaves, bytes32 nodeDomain)
        private
        pure
        returns (bytes32 root, bytes32[] memory path0, bytes32[] memory path1)
    {
        uint256 depth;
        for (uint256 width = leaves.length; width > 1; width = (width + 1) / 2) {
            ++depth;
        }
        path0 = new bytes32[](depth);
        path1 = new bytes32[](depth);
        uint256 index0;
        uint256 index1 = 1;
        bytes32[] memory level = leaves;
        uint256 levelNumber;
        while (level.length > 1) {
            uint256 sibling0 = index0 ^ 1;
            if (sibling0 >= level.length) sibling0 = index0;
            uint256 sibling1 = index1 ^ 1;
            if (sibling1 >= level.length) sibling1 = index1;
            path0[levelNumber] = level[sibling0];
            path1[levelNumber] = level[sibling1];

            uint256 nextLength = (level.length + 1) / 2;
            bytes32[] memory next = new bytes32[](nextLength);
            for (uint256 i; i < level.length; i += 2) {
                bytes32 right = i + 1 < level.length ? level[i + 1] : level[i];
                next[i / 2] = keccak256(abi.encodePacked(nodeDomain, level[i], right));
            }
            level = next;
            index0 >>= 1;
            index1 >>= 1;
            ++levelNumber;
        }
        root = level[0];
    }

    function _decimal(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0";
        uint256 digits;
        for (uint256 n = value; n != 0; n /= 10) {
            ++digits;
        }
        bytes memory output = new bytes(digits);
        while (value != 0) {
            output[--digits] = bytes1(uint8(48 + (value % 10)));
            value /= 10;
        }
        return string(output);
    }
}
