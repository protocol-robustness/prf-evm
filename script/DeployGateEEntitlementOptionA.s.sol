// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SP1Verifier} from "@sp1-contracts/v6.1.0/SP1VerifierGroth16.sol";
import {IPrfStatementAdmission} from "../src/interfaces/IPrfStatementAdmission.sol";
import {ISP1Verifier} from "../src/verification/interfaces/ISP1Verifier.sol";
import {PrfChainInstanceGenesis} from "../src/core/PrfChainInstanceGenesis.sol";
import {PrfVerifierRegistry} from "../src/core/PrfVerifierRegistry.sol";
import {PrfStatementAdmission} from "../src/core/PrfStatementAdmission.sol";
import {SewGovernanceAuthorityAdapter} from "../src/integrations/sew/SewGovernanceAuthorityAdapter.sol";
import {SewConfigurationExecutor} from "../src/integrations/sew/SewConfigurationExecutor.sol";
import {
    PrfSourceBoundEntitlementVerifierAdapterV1
} from "../src/verification/adapters/PrfSourceBoundEntitlementVerifierAdapterV1.sol";
import {ProductionProRataAllocatorV2} from "../src/applications/pro-rata/ProductionProRataAllocatorV2.sol";
import {OnchainShortfallReserveV2} from "../src/applications/shortfall/OnchainShortfallReserveV2.sol";
import {SourceBoundProRataControllerV2} from "../src/applications/shortfall/SourceBoundProRataControllerV2.sol";
import {
    SourceBoundProRataEntitlementAssuranceV1
} from "../src/applications/shortfall/SourceBoundProRataEntitlementAssuranceV1.sol";
import {
    SourceBoundProRataEntitlementRatificationControllerV1
} from "../src/applications/shortfall/SourceBoundProRataEntitlementRatificationControllerV1.sol";
import {SourceBoundEntitlementV1Commitments} from "../src/verification/SourceBoundEntitlementV1Commitments.sol";

/// @notice Deployment producer for the additive 288-byte entitlement Gate E path.
/// @dev Starts a local proof-bound topology; the execution caller is bound by
///      the Gate E test harness after deployment, as in the historical test path.
contract DeployGateEEntitlementOptionA is Script {
    uint256 internal constant INITIAL_CAPITAL = 80;
    uint256 internal constant PROTECTED_CAPITAL = 10;

    function run() external {
        uint256 key = vm.envUint("PRIVATE_KEY");
        bytes32 protocolRoot = vm.envBytes32("GATE_E_PROTOCOL_GENESIS_ROOT");
        bytes32 authorityStateRoot = vm.envBytes32("GATE_E_AUTHORITY_STATE_ROOT");
        bytes32 chainInstanceRoot = vm.envBytes32("GATE_E_CHAIN_INSTANCE_GENESIS_ROOT");
        bytes32 configRoot = vm.envBytes32("GATE_E_CONFIGURATION_ROOT_0");
        bytes32 operationId = vm.envBytes32("GATE_E_OPERATION_ID");
        bytes32 policyRoot = vm.envBytes32("GATE_E_POLICY_ROOT");
        bytes32 reserveBindingRoot = vm.envBytes32("GATE_E_RESERVE_BINDING_ROOT");
        bytes32 sourceProgramVKey = vm.envBytes32("GATE_E_SOURCE_PROGRAM_VKEY");
        bytes32 sourceProgramElfSha256 = vm.envBytes32("GATE_E_SOURCE_PROGRAM_ELF_SHA256");
        bytes32 sourceVerifierId = vm.envBytes32("GATE_E_SOURCE_VERIFIER_ID");
        bytes32 executionVerifierId = vm.envBytes32("GATE_E_EXECUTION_VERIFIER_ID");
        bytes32 executionStatementSchema = vm.envBytes32("GATE_E_EXECUTION_STATEMENT_SCHEMA");
        bytes32 executionPublicValuesSchema = vm.envBytes32("GATE_E_EXECUTION_PUBLIC_VALUES_SCHEMA");
        address residualRecipient = vm.envAddress("GATE_E_RESIDUAL_RECIPIENT");
        require(
            operationId != bytes32(0) && policyRoot != bytes32(0) && reserveBindingRoot != bytes32(0)
                && sourceProgramVKey != bytes32(0) && sourceProgramElfSha256 != bytes32(0)
                && sourceVerifierId != bytes32(0) && residualRecipient != address(0),
            "GateE entitlement: missing identity input"
        );

        vm.startBroadcast(key);
        address authority = vm.addr(key);
        SewGovernanceAuthorityAdapter authorityAdapter =
            new SewGovernanceAuthorityAdapter(protocolRoot, authority, authorityStateRoot);
        PrfChainInstanceGenesis genesis = new PrfChainInstanceGenesis(
            protocolRoot, block.chainid, 1, address(authorityAdapter), authorityStateRoot, configRoot, authority
        );
        genesis.sealGenesis(chainInstanceRoot, address(genesis).codehash, address(authorityAdapter).codehash);

        SP1Verifier sp1Verifier = new SP1Verifier();
        PrfSourceBoundEntitlementVerifierAdapterV1 sourceAdapter =
            new PrfSourceBoundEntitlementVerifierAdapterV1(
                ISP1Verifier(address(sp1Verifier)), sourceProgramVKey, sourceProgramElfSha256
            );
        PrfVerifierRegistry registry = new PrfVerifierRegistry(authority);
        bytes32 registryRoot = _registerAndSeal(registry, sourceAdapter, sourceVerifierId, sourceProgramVKey, sourceProgramElfSha256);
        SewConfigurationExecutor executor = new SewConfigurationExecutor(genesis, authorityAdapter, registry, registryRoot);
        PrfStatementAdmission admission =
            new PrfStatementAdmission(genesis, executor, registry, configRoot, 0);

        LocalEntitlementGateEToken gateToken = new LocalEntitlementGateEToken(authority, INITIAL_CAPITAL);
        ProductionProRataAllocatorV2 allocator = new ProductionProRataAllocatorV2(authority);
        OnchainShortfallReserveV2 reserve =
            new OnchainShortfallReserveV2(IERC20(address(gateToken)), authority, PROTECTED_CAPITAL, allocator);
        SourceBoundProRataControllerV2 prepared = new SourceBoundProRataControllerV2();
        SourceBoundProRataEntitlementAssuranceV1 assurance = new SourceBoundProRataEntitlementAssuranceV1(
            IPrfStatementAdmission(address(admission)), sourceAdapter, prepared, authority
        );
        SourceBoundProRataEntitlementRatificationControllerV1 ratification =
            new SourceBoundProRataEntitlementRatificationControllerV1(prepared, assurance, reserve);

        prepared.bindRatificationController(address(ratification));
        allocator.bindFundingAuthority(address(reserve));
        reserve.bindRatificationAuthority(address(ratification));
        assurance.bindRatificationController(address(ratification));

        SourceBoundEntitlementV1Commitments.PreparedOperation memory operation;
        operation.operationId = operationId;
        operation.initiator = authority;
        operation.chainId = uint128(block.chainid);
        operation.reserve = address(reserve);
        operation.token = address(gateToken);
        operation.allocator = address(allocator);
        operation.configurationRoot = configRoot;
        operation.configurationEpoch = 0;
        operation.sourceVerifierId = sourceVerifierId;
        operation.executionVerifierId = executionVerifierId;
        operation.sourceProgramVKey = sourceProgramVKey;
        operation.sourceProgramElfSha256 = sourceProgramElfSha256;
        operation.sourceStatementSchema = sourceAdapter.statementSchemaVersion();
        operation.sourcePublicValuesSchema = sourceAdapter.publicValuesSchema();
        operation.executionStatementSchema = executionStatementSchema;
        operation.executionPublicValuesSchema = executionPublicValuesSchema;
        operation.policyRoot = policyRoot;
        operation.beneficiaryProfile = SourceBoundEntitlementV1Commitments.BeneficiaryProfile.SmartAccountV1;
        operation.residualRecipient = residualRecipient;
        bytes32 preparedRoot = prepared.prepareEntitlementOperation(operation);

        require(IERC20(address(gateToken)).approve(address(reserve), INITIAL_CAPITAL), "GateE: approve");
        reserve.deposit(INITIAL_CAPITAL);
        bytes32 reserveCommitment = reserve.economicState(preparedRoot).commitment;
        vm.stopBroadcast();

        OnchainShortfallReserveV2.EconomicState memory economics = reserve.economicState(preparedRoot);
        string memory manifest = string(
            abi.encodePacked(
                '{"schema":"prf-evm.gate-e-entitlement-deployment.v1","chainId":',
                vm.toString(block.chainid),
                ',"deployer":"', vm.toString(authority),
                '","programId":"source-bound-entitlement-sp1-program.v1","programVKey":"',
                vm.toString(sourceProgramVKey), '","programElfSha256":"', vm.toString(sourceProgramElfSha256),
                '","sourceStatementSchema":"', vm.toString(sourceAdapter.statementSchemaVersion()),
                '","publicValuesSchema":"', vm.toString(sourceAdapter.publicValuesSchema()),
                '","preparedOperationRoot":"', vm.toString(preparedRoot),
                '","reserveStateCommitment":"', vm.toString(reserveCommitment),
                '","operationId":"', vm.toString(operationId),
                '","configurationRoot":"', vm.toString(configRoot),
                '","configurationEpoch":0,"policyRoot":"', vm.toString(policyRoot),
                '","reserveBindingRoot":"', vm.toString(reserveBindingRoot),
                '","beneficiaryProfile":"smart-account-v1","registryRoot":"', vm.toString(registryRoot),
                '","economicReserveState":{"grossBalance":"', vm.toString(economics.grossBalance),
                '","reservedBefore":"', vm.toString(economics.reservedBefore),
                '","protectedCapital":"', vm.toString(economics.protectedAmount),
                '","availableAmount":"', vm.toString(economics.availableAmount),
                '","availabilityRevision":"', vm.toString(uint256(economics.revision)),
                '"},"contracts":{"token":"', vm.toString(address(gateToken)),
                '","reserve":"', vm.toString(address(reserve)),
                '","allocator":"', vm.toString(address(allocator)),
                '","preparedController":"', vm.toString(address(prepared)),
                '","assurance":"', vm.toString(address(assurance)),
                '","ratificationController":"', vm.toString(address(ratification)),
                '","admission":"', vm.toString(address(admission)),
                '","sourceAdapter":"', vm.toString(address(sourceAdapter)),
                '","verifier":"', vm.toString(address(sp1Verifier)),
                '","registry":"', vm.toString(address(registry)),
                '","executor":"', vm.toString(address(executor)),
                '","genesis":"', vm.toString(address(genesis)),
                '"},"localOnly":{"sourceVerifierId":"', vm.toString(sourceVerifierId),
                '","executionVerifierId":"', vm.toString(executionVerifierId),
                '","executionStatementSchema":"', vm.toString(executionStatementSchema),
                '","executionPublicValuesSchema":"', vm.toString(executionPublicValuesSchema),
                '","residualRecipient":"', vm.toString(residualRecipient), '"}}'
            )
        );
        console2.log("GATE_E_ENTITLEMENT_MANIFEST_JSON", manifest);
    }

    function _registerAndSeal(
        PrfVerifierRegistry registry,
        PrfSourceBoundEntitlementVerifierAdapterV1 adapter,
        bytes32 verifierId,
        bytes32 vkey,
        bytes32 elfHash
    ) private returns (bytes32 root) {
        bytes32[] memory ids = new bytes32[](1);
        address[] memory adapters = new address[](1);
        bytes32[] memory vkeys = new bytes32[](1);
        bytes32[] memory elfs = new bytes32[](1);
        string[] memory programs = new string[](1);
        bytes32[] memory statements = new bytes32[](1);
        bytes32[] memory publicValuesSchemas = new bytes32[](1);
        bool[] memory active = new bool[](1);
        ids[0] = verifierId;
        adapters[0] = address(adapter);
        vkeys[0] = vkey;
        elfs[0] = elfHash;
        programs[0] = "source-bound-entitlement-sp1-program.v1";
        statements[0] = adapter.statementSchemaVersion();
        publicValuesSchemas[0] = adapter.publicValuesSchema();
        active[0] = true;
        root = registry.computeCanonicalRoot(ids, adapters, vkeys, elfs, programs, statements, publicValuesSchemas, active);

        bytes32[] memory emptyIds = new bytes32[](0);
        address[] memory emptyAdapters = new address[](0);
        bytes32[] memory emptyWords = new bytes32[](0);
        string[] memory emptyStrings = new string[](0);
        bool[] memory emptyActive = new bool[](0);
        bytes32 emptyRoot = registry.computeCanonicalRoot(
            emptyIds, emptyAdapters, emptyWords, emptyWords, emptyStrings, emptyWords, emptyWords, emptyActive
        );
        registry.sealRegistry(emptyRoot);
        registry.registerVerifier(
            root, verifierId, address(adapter), vkey, elfHash, programs[0], statements[0], publicValuesSchemas[0]
        );
        registry.sealRegistry(root);
    }
}

contract LocalEntitlementGateEToken is IERC20 {
    string public constant name = "Gate E entitlement capital";
    string public constant symbol = "GEV1";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(address recipient, uint256 amount) {
        balanceOf[recipient] = amount;
        totalSupply = amount;
        emit Transfer(address(0), recipient, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 permitted = allowance[from][msg.sender];
        require(permitted >= amount, "allowance");
        allowance[from][msg.sender] = permitted - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) private {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
