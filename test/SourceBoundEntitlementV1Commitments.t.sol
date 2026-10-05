// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {SourceBoundEntitlementV1Commitments as C} from "../src/verification/SourceBoundEntitlementV1Commitments.sol";
import {SourceBoundProRataControllerV2} from "../src/applications/shortfall/SourceBoundProRataControllerV2.sol";

contract SourceBoundEntitlementV1CommitmentsTest is Test {
    bytes32 private constant VECTOR_A_ROOT = 0x074d2328382cb8a472f6bc082df16584ecd96516ea3a9298f633f95a8e2e48b6;

    function test_PreparedOperationRootMatchesB2VectorA() public {
        assertEq(C.preparedOperationRoot(_vectorA()), VECTOR_A_ROOT);
    }

    function test_BeneficiaryProfileIsCommitted() public {
        C.PreparedOperation memory operation = _vectorA();
        bytes32 smartAccountRoot = C.preparedOperationRoot(operation);
        operation.beneficiaryProfile = C.BeneficiaryProfile.ImmutableAddressV1;
        assertTrue(C.preparedOperationRoot(operation) != smartAccountRoot);
    }

    function test_AdditiveControllerPreparationStoresSuccessorIdentityAndProfile() public {
        SourceBoundProRataControllerV2 controller = new SourceBoundProRataControllerV2();
        C.PreparedOperation memory operation = _vectorA();
        operation.initiator = address(this);
        operation.chainId = uint128(block.chainid);
        bytes32 root = controller.prepareEntitlementOperation(operation);

        assertEq(root, controller.preparedOperationRoot(operation.operationId));
        assertTrue(controller.successorEntitlementProfile(operation.operationId));
        assertEq(controller.preparedBeneficiaryProfileWord(operation.operationId), keccak256("smart-account-v1"));
        assertEq(
            controller.preparedResidualRecipient(operation.operationId),
            bytes32(uint256(uint160(operation.residualRecipient)))
        );
    }

    function _vectorA() private pure returns (C.PreparedOperation memory operation) {
        operation = C.PreparedOperation({
            operationId: 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,
            initiator: 0x1111111111111111111111111111111111111111,
            chainId: 31337,
            reserve: 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512,
            token: 0x5FbDB2315678afecb367f032d93F642f64180aa3,
            allocator: 0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0,
            configurationRoot: 0x0101010101010101010101010101010101010101010101010101010101010101,
            configurationEpoch: 7,
            sourceVerifierId: 0x0202020202020202020202020202020202020202020202020202020202020202,
            executionVerifierId: 0x0303030303030303030303030303030303030303030303030303030303030303,
            sourceProgramVKey: 0x0404040404040404040404040404040404040404040404040404040404040404,
            sourceProgramElfSha256: 0x0505050505050505050505050505050505050505050505050505050505050505,
            sourceStatementSchema: 0x0606060606060606060606060606060606060606060606060606060606060606,
            sourcePublicValuesSchema: 0xa069c379e311996c73ea1f69edb070bfddbb573b770b3c5aec52bad4b255aa87,
            executionStatementSchema: 0x0707070707070707070707070707070707070707070707070707070707070707,
            executionPublicValuesSchema: 0x0808080808080808080808080808080808080808080808080808080808080808,
            policyRoot: 0x0909090909090909090909090909090909090909090909090909090909090909,
            beneficiaryProfile: C.BeneficiaryProfile.SmartAccountV1,
            residualRecipient: 0x2222222222222222222222222222222222222222
        });
    }
}
