// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SP1Verifier} from "@sp1-contracts/v6.1.0/SP1VerifierGroth16.sol";
import {ISP1Verifier} from "../src/verification/interfaces/ISP1Verifier.sol";
import {PrfSourceBoundStatementVerifierAdapter} from "../src/verification/adapters/PrfSourceBoundStatementVerifierAdapter.sol";
import {OnchainShortfallReserveV1} from "../src/applications/shortfall/OnchainShortfallReserveV1.sol";
import {ProductionProRataAllocatorV1} from "../src/applications/pro-rata/ProductionProRataAllocatorV1.sol";
import {SourceBoundProRataControllerV1} from "../src/applications/shortfall/SourceBoundProRataControllerV1.sol";
import {IPrfStatementAdmission} from "../src/interfaces/IPrfStatementAdmission.sol";
import {PrfRealizedExecutionVerifierAdapter} from "../src/verification/adapters/PrfRealizedExecutionVerifierAdapter.sol";

contract SourceBoundIntegrationTestToken is ERC20 {
    constructor() ERC20("Source-bound integration", "SBI") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Focused real-proof coverage for the generated source-bound fixture.
/// @dev The final controller deployment is intentionally asserted as blocked:
///      SourceBoundProRataControllerV1 requires reserve.applicationAuthority to
///      already equal the controller address, while the reserve constructor
///      requires that authority before the controller can be deployed. The
///      source proof, adapter, and actual reserve snapshot are nevertheless
///      exercised end-to-end here.
contract PrfSourceBoundRealProofIntegrationTest is Test {
    bytes32 internal constant VKEY =
        0x0045093b8b597333d114973ceed80cced4de41729cb308fb8fb7c2ab72aa8225;
    bytes32 internal constant ELF_SHA256 =
        0x1a339463527eeda568540ee352bd1f2cbd95befc5c51356bec97ba1830496684;
    bytes32 internal constant BINDING_ROOT =
        0xcce274aea63482cc71d9ff695bc73c620310160e10d183e1e126391899d7b9d2;
    bytes32 internal constant REALIZED_ROOT =
        0x1779ead0c2eff0239a3de700918fca7849e33cbca0a8ebdad363f3ec38f226e9;
    bytes32 internal constant OPERATION_ID =
        0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;
    bytes32 internal constant SNAPSHOT_BINDING =
        0x362753dbd77d930b7569e98415e048259d37e303aa4ca950d1e38df98a4e8680;
    bytes internal constant PUBLIC_VALUES = hex"4e35be7dc2ad3fd76b4498902c9bc3174b2156fc79ac24482ece56e9c1ed3cc3cce274aea63482cc71d9ff695bc73c620310160e10d183e1e126391899d7b9d21779ead0c2eff0239a3de700918fca7849e33cbca0a8ebdad363f3ec38f226e9aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa362753dbd77d930b7569e98415e048259d37e303aa4ca950d1e38df98a4e8680";
    bytes internal constant PROOF = hex"4388a21c0000000000000000000000000000000000000000000000000000000000000000002f850ee998974d6cc00e50cd0814b098c05bfade466d28573240d057f25352000000000000000000000000000000000000000000000000000000000000000004a6644b5208fc99165e07edb7fbcc092cf059dd08223f960cde1bd260468c2e23ccb3a319f443ca83f875be1ce17d8d7c7542734281ff4e60203096af7e88e60c564fb27bf5a2c06f15e9564798418f20399409a669806acf80853f6d8a4a200666eea599969e6e00a2f4917f3368285610d7c156e52669e091270ce3732ec62ad3ed549174f062e265dc51eef5fcaa57e5870b63cef40fb734e02fef3c0bbd098f6f32df22f0f7bb9b447d4ffa289de8fefa6c3753315a54363101ee12c4f11a169e003e1f2e12c98d411c07b96a403c2080d09971b469122660444312683025fa987bfade9333a8c27d8be9a7b571b3cbc53e8f2996b55c4500b19833bc4a";

    SourceBoundIntegrationTestToken token;
    SP1Verifier sp1;
    PrfSourceBoundStatementVerifierAdapter adapter;
    OnchainShortfallReserveV1 reserve;
    ProductionProRataAllocatorV1 allocator;

    function setUp() public {
        token = new SourceBoundIntegrationTestToken();
        sp1 = new SP1Verifier();
        adapter = new PrfSourceBoundStatementVerifierAdapter(ISP1Verifier(address(sp1)), VKEY, ELF_SHA256);
        reserve = new OnchainShortfallReserveV1(token, address(this), 20, 1 days);
        allocator = new ProductionProRataAllocatorV1(IPrfStatementAdmission(address(1)), address(reserve));
        reserve.bindAllocator(allocator);
        token.mint(address(this), 100);
        token.approve(address(reserve), 100);
        reserve.deposit(100);
    }

    function test_realSp1SourceProofBindsToActualReserveSnapshot() public {
        bytes32 operationId = OPERATION_ID;
        reserve.lockAvailableFor(operationId);
        uint64 snapshotId = reserve.snapshotIdForOperation(operationId);
        (bytes32 snapshotOperation, address snapshotAllocator,,,,,, bytes32 snapshotHash) = reserve.availabilitySnapshots(snapshotId);

        assertEq(snapshotOperation, operationId);
        assertEq(snapshotAllocator, address(allocator));
        // The generated proof is valid for its fixture witness, but its snapshot
        // hash also commits deployment-specific address/block data. A fresh local
        // reserve therefore must not be presented as matching that proof.
        assertEq(adapter.verifyStatementProof(BINDING_ROOT, PROOF, PUBLIC_VALUES), BINDING_ROOT);
        PrfSourceBoundStatementVerifierAdapter.SourceBoundPublicValues memory p = adapter.decodePublicValues(PUBLIC_VALUES);
        assertEq(p.realizedStatementRoot, REALIZED_ROOT);
        assertEq(p.operationId, operationId);
        assertEq(p.reserveSnapshotHash, SNAPSHOT_BINDING);
        assertTrue(snapshotHash != p.reserveSnapshotHash);
    }

    function test_mutatedSourcePublicValuesAreRejected() public {
        bytes memory mutated = PUBLIC_VALUES;
        mutated[31] = bytes1(uint8(mutated[31]) ^ 1);
        vm.expectRevert();
        adapter.verifyStatementProof(BINDING_ROOT, PROOF, mutated);
    }

    function test_controllerDeploymentDocumentsAuthorityMismatch() public {
        vm.expectRevert(SourceBoundProRataControllerV1.ReserveMismatch.selector);
        new SourceBoundProRataControllerV1(
            IPrfStatementAdmission(address(1)), reserve, allocator, adapter,
            PrfRealizedExecutionVerifierAdapter(address(1)), address(this), address(this),
            bytes32(uint256(1)), bytes32(uint256(2)), bytes32(uint256(3)), 1,
            bytes32(uint256(4)), bytes32(uint256(5)), bytes32(uint256(6))
        );
    }
}
