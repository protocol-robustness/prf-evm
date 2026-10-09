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
    PrfSourceBoundStatementVerifierAdapterV2
} from "../src/verification/adapters/PrfSourceBoundStatementVerifierAdapterV2.sol";
import {ProductionProRataAllocatorV2} from "../src/applications/pro-rata/ProductionProRataAllocatorV2.sol";
import {OnchainShortfallReserveV2} from "../src/applications/shortfall/OnchainShortfallReserveV2.sol";
import {SourceBoundProRataControllerV2} from "../src/applications/shortfall/SourceBoundProRataControllerV2.sol";
import {SourceBoundProRataAssuranceV2} from "../src/applications/shortfall/SourceBoundProRataAssuranceV2.sol";
import {
    SourceBoundProRataRatificationControllerV2
} from "../src/applications/shortfall/SourceBoundProRataRatificationControllerV2.sol";
import {ShortfallV2Commitments} from "../src/verification/ShortfallV2Commitments.sol";

/// @notice Gate E coherent deployment producer (Option A).
///
/// Unlike DeployGateE.s.sol — which performs a governed `applyConfiguration`
/// transition to epoch 1 — this producer deploys the entire admission layer in a
/// bootstrap-conforming state at epoch 0:
///
///   - the real V2 source adapter is registered and SEALED in the registry at
///     root R1 BEFORE the executor + admission are constructed;
///   - SewConfigurationExecutor is constructed directly with
///     initialVerifierRegistryRoot_ == R1, currentConfigurationRoot == genesis
///     initialConfigurationRoot (epoch 0), satisfying every
///     PrfStatementAdmission._checkConfigurationBinding() requirement with no
///     post-genesis governance transition;
///   - PrfStatementAdmission is bound to (configRoot0, epoch 0).
///
/// This keeps all PRF contracts unchanged and keeps the shortfall family wired
/// to a single coherent admission. Prepared-operation fields that the deployment
/// manifest does not commit (source/execution verifier ids, execution schemas,
/// policy root, residual recipient, operation id) are explicit LOCAL-ONLY inputs
/// supplied by the operator; they are documented as such and are not presented as
/// deployment-committed evidence.
contract DeployGateEOptionA is Script {
    uint256 internal constant INITIAL_CAPITAL = 100;
    uint256 internal constant PROTECTED_CAPITAL = 10;

    /// @notice Deploys the coherent epoch-0 topology and prepares the operation +
    ///         reserve basis so a deployment-derived proof can be generated against
    ///         this exact live state.
    function run()
        external
        returns (
            address token,
            address reserve,
            address allocator,
            address admission,
            bytes32 preparedRoot,
            bytes32 reserveCommitment
        )
    {
        uint256 key = vm.envUint("PRIVATE_KEY");
        bytes32 protocolRoot = vm.envBytes32("GATE_E_PROTOCOL_GENESIS_ROOT");
        bytes32 authorityStateRoot = vm.envBytes32("GATE_E_AUTHORITY_STATE_ROOT");
        bytes32 chainInstanceRoot = vm.envBytes32("GATE_E_CHAIN_INSTANCE_GENESIS_ROOT");
        // genesis initialConfigurationRoot == admission expectedConfigurationRoot == configRoot0 (epoch 0)
        bytes32 configRoot0 = vm.envBytes32("GATE_E_CONFIGURATION_ROOT_0");
        bytes32 sourceProgramVKey = vm.envBytes32("GATE_E_SOURCE_PROGRAM_VKEY");
        bytes32 sourceProgramElfSha256 = vm.envBytes32("GATE_E_SOURCE_PROGRAM_ELF_SHA256");
        // LOCAL-ONLY prepared-operation fields (not deployment-committed):
        bytes32 operationId = vm.envBytes32("GATE_E_OPERATION_ID");
        bytes32 policyRoot = vm.envBytes32("GATE_E_POLICY_ROOT");
        bytes32 allocationBindingRoot = vm.envBytes32("GATE_E_ALLOCATION_BINDING_ROOT");
        bytes32 realizedStatementRoot = vm.envBytes32("GATE_E_REALIZED_STATEMENT_ROOT");
        address residualRecipient = vm.envAddress("GATE_E_RESIDUAL_RECIPIENT");
        bytes32 sourceVerifierId = vm.envBytes32("GATE_E_SOURCE_VERIFIER_ID");
        bytes32 executionVerifierId = vm.envBytes32("GATE_E_EXECUTION_VERIFIER_ID");
        bytes32 sourceStatementSchema = vm.envBytes32("GATE_E_SOURCE_STATEMENT_SCHEMA");
        bytes32 sourcePublicValuesSchema = keccak256("prf/onchain-shortfall-allocation-binding-public-values.v2");
        bytes32 executionStatementSchema = vm.envBytes32("GATE_E_EXECUTION_STATEMENT_SCHEMA");
        bytes32 executionPublicValuesSchema = vm.envBytes32("GATE_E_EXECUTION_PUBLIC_VALUES_SCHEMA");
        uint64 configurationEpoch = 0; // Option A keeps admission at epoch 0

        vm.startBroadcast(key);
        address authority = vm.addr(key);

        SewGovernanceAuthorityAdapter authorityAdapter =
            new SewGovernanceAuthorityAdapter(protocolRoot, authority, authorityStateRoot);
        PrfChainInstanceGenesis genesis = new PrfChainInstanceGenesis(
            protocolRoot, block.chainid, 1, address(authorityAdapter), authorityStateRoot, configRoot0, authority
        );
        genesis.sealGenesis(chainInstanceRoot, address(genesis).codehash, address(authorityAdapter).codehash);
        SP1Verifier sp1Verifier = new SP1Verifier();
        PrfSourceBoundStatementVerifierAdapterV2 sourceAdapter = new PrfSourceBoundStatementVerifierAdapterV2(
            ISP1Verifier(address(sp1Verifier)), sourceProgramVKey, sourceProgramElfSha256
        );
        PrfVerifierRegistry verifierRegistry = new PrfVerifierRegistry(authority);

        // Register + SEAL the real V2 adapter at canonical root R1 BEFORE the
        // executor/admission are constructed, so the executor can be deployed
        // already pointing at a sealed registry root at epoch 0.
        bytes32[] memory ids = new bytes32[](1);
        address[] memory adapters = new address[](1);
        bytes32[] memory vkeys = new bytes32[](1);
        bytes32[] memory elfs = new bytes32[](1);
        string[] memory programIds = new string[](1);
        bytes32[] memory schemas = new bytes32[](1);
        bytes32[] memory pvSchemas = new bytes32[](1);
        bool[] memory active = new bool[](1);
        ids[0] = sourceVerifierId;
        adapters[0] = address(sourceAdapter);
        vkeys[0] = sourceProgramVKey;
        elfs[0] = sourceProgramElfSha256;
        programIds[0] = "source-bound-shortfall-allocation.v1";
        schemas[0] = sourceStatementSchema;
        pvSchemas[0] = sourcePublicValuesSchema;
        active[0] = true;
        bytes32 registryRoot1 =
            verifierRegistry.computeCanonicalRoot(ids, adapters, vkeys, elfs, programIds, schemas, pvSchemas, active);
        bytes32[] memory emptyIds = new bytes32[](0);
        address[] memory emptyAdapters = new address[](0);
        bytes32[] memory emptyWords = new bytes32[](0);
        string[] memory emptyStrings = new string[](0);
        bool[] memory emptyActive = new bool[](0);
        bytes32 registryRoot0 = verifierRegistry.computeCanonicalRoot(
            emptyIds, emptyAdapters, emptyWords, emptyWords, emptyStrings, emptyWords, emptyWords, emptyActive
        );
        verifierRegistry.sealRegistry(registryRoot0);
        verifierRegistry.registerVerifier(
            registryRoot1, ids[0], adapters[0], vkeys[0], elfs[0], programIds[0], schemas[0], pvSchemas[0]
        );
        verifierRegistry.sealRegistry(registryRoot1);

        // Option A: executor constructed directly at sealed R1 + config0 + epoch 0.
        // No applyConfiguration, so currentConfigurationRoot stays configRoot0 and
        // currentEpoch stays 0 — matching the admission binding exactly.
        SewConfigurationExecutor executor =
            new SewConfigurationExecutor(genesis, authorityAdapter, verifierRegistry, registryRoot1);

        PrfStatementAdmission deployedAdmission =
            new PrfStatementAdmission(genesis, executor, verifierRegistry, configRoot0, configurationEpoch);

        LocalGateEToken gateToken = new LocalGateEToken(authority, INITIAL_CAPITAL);
        ProductionProRataAllocatorV2 deployedAllocator = new ProductionProRataAllocatorV2(authority, executor);
        OnchainShortfallReserveV2 deployedReserve =
            new OnchainShortfallReserveV2(IERC20(address(gateToken)), authority, PROTECTED_CAPITAL, deployedAllocator);
        SourceBoundProRataControllerV2 preparedController = new SourceBoundProRataControllerV2();
        SourceBoundProRataAssuranceV2 assurance = new SourceBoundProRataAssuranceV2(
            IPrfStatementAdmission(address(deployedAdmission)), sourceAdapter, preparedController, authority
        );
        SourceBoundProRataRatificationControllerV2 ratification =
            new SourceBoundProRataRatificationControllerV2(preparedController, assurance, deployedReserve);

        preparedController.bindRatificationController(address(ratification));
        deployedAllocator.bindFundingAuthority(address(deployedReserve));
        deployedReserve.bindRatificationAuthority(address(ratification));
        assurance.bindRatificationController(address(ratification));

        // ---- Consistency assertions (deployment verification) ----
        require(executor.currentEpoch() == 0, "OptionA: epoch0");
        require(executor.currentConfigurationRoot() == configRoot0, "OptionA: config0");
        require(executor.currentVerifierRegistryRoot() == registryRoot1, "OptionA: sealed registry");
        require(verifierRegistry.isSealed(registryRoot1), "OptionA: R1 sealed");
        require(verifierRegistry.canonicalRoot(registryRoot1) == registryRoot1, "OptionA: R1 canonical");
        require(
            deployedAdmission.expectedConfigurationRoot() == configRoot0
                && deployedAdmission.expectedConfigurationEpoch() == 0,
            "OptionA: admission binding"
        );
        require(
            address(deployedAdmission.verifierRegistry()) == address(verifierRegistry), "OptionA: admission registry"
        );
        require(address(sourceAdapter.sp1Verifier()) == address(sp1Verifier), "OptionA: adapter verifier");
        require(deployedAllocator.fundingAuthority() == address(deployedReserve), "OptionA: allocator binding");
        require(deployedReserve.ratificationAuthority() == address(ratification), "OptionA: reserve binding");
        require(
            preparedController.ratificationController() == address(ratification), "OptionA: prepared controller binding"
        );
        require(assurance.ratificationController() == address(ratification), "OptionA: assurance binding");
        require(address(assurance.admission()) == address(deployedAdmission), "OptionA: assurance admission");

        // Prepare operation + establish live reserve basis (LOCAL-ONLY fields).
        ShortfallV2Commitments.PreparedOperation memory operation = ShortfallV2Commitments.PreparedOperation({
            operationId: operationId,
            initiator: bytes32(uint256(uint160(authority))),
            chainId: uint64(block.chainid),
            reserve: bytes32(uint256(uint160(address(deployedReserve)))),
            token: bytes32(uint256(uint160(address(gateToken)))),
            allocator: bytes32(uint256(uint160(address(deployedAllocator)))),
            configurationRoot: configRoot0,
            configurationEpoch: configurationEpoch,
            sourceVerifierId: sourceVerifierId,
            executionVerifierId: executionVerifierId,
            sourceProgramVKey: sourceProgramVKey,
            sourceProgramElfSha256: sourceProgramElfSha256,
            sourceStatementSchema: sourceStatementSchema,
            sourcePublicValuesSchema: sourcePublicValuesSchema,
            executionStatementSchema: executionStatementSchema,
            executionPublicValuesSchema: executionPublicValuesSchema,
            policyRoot: policyRoot,
            residualRecipient: bytes32(uint256(uint160(residualRecipient)))
        });
        preparedRoot = preparedController.prepareOperation(operation);
        IERC20(address(gateToken)).approve(address(deployedReserve), INITIAL_CAPITAL);
        deployedReserve.deposit(INITIAL_CAPITAL);
        reserveCommitment = deployedReserve.economicState(preparedRoot).commitment;

        vm.stopBroadcast();

        token = address(gateToken);
        reserve = address(deployedReserve);
        allocator = address(deployedAllocator);
        admission = address(deployedAdmission);
        _writeManifest(
            token,
            reserve,
            allocator,
            admission,
            address(preparedController),
            address(assurance),
            address(ratification),
            address(sourceAdapter),
            address(verifierRegistry),
            registryRoot1,
            preparedRoot,
            reserveCommitment,
            configRoot0,
            configurationEpoch,
            operationId,
            policyRoot,
            allocationBindingRoot,
            realizedStatementRoot
        );
    }

    function _writeManifest(
        address token,
        address reserve,
        address allocator,
        address admission,
        address preparedController,
        address assurance,
        address ratification,
        address sourceAdapter,
        address verifierRegistry,
        bytes32 registryRoot1,
        bytes32 preparedRoot,
        bytes32 reserveCommitment,
        bytes32 configRoot0,
        uint64 configurationEpoch,
        bytes32 operationId,
        bytes32 policyRoot,
        bytes32 allocationBindingRoot,
        bytes32 realizedStatementRoot
    ) private {
        OnchainShortfallReserveV2.EconomicState memory reserveState =
            OnchainShortfallReserveV2(reserve).economicState(preparedRoot);
        require(reserveState.commitment == reserveCommitment, "GateE: reserve commitment changed");
        string memory root = string(
            abi.encodePacked(
                '{"schema":"prf-evm.gate-e-deployment.v1","chainId":',
                vm.toString(block.chainid),
                ',"deploymentTxs":[],"option":"A","epoch":0',
                ',"deployer":"',
                vm.toString(vm.addr(vm.envUint("PRIVATE_KEY"))),
                '","contracts":{"token":"',
                vm.toString(token),
                '","reserve":"',
                vm.toString(reserve),
                '","allocator":"',
                vm.toString(allocator),
                '","preparedController":"',
                vm.toString(preparedController),
                '","assurance":"',
                vm.toString(assurance),
                '","ratificationController":"',
                vm.toString(ratification),
                '","admission":"',
                vm.toString(admission),
                '","sourceAdapter":"',
                vm.toString(sourceAdapter),
                '","verifierRegistry":"',
                vm.toString(verifierRegistry),
                '"}',
                ',"registryRoot1":"',
                vm.toString(registryRoot1),
                '","preparedOperationRoot":"',
                vm.toString(preparedRoot),
                '","reserveStateCommitment":"',
                vm.toString(reserveCommitment),
                '","economicReserveState":{"grossBalance":"',
                vm.toString(reserveState.grossBalance),
                '","reservedBefore":"',
                vm.toString(reserveState.reservedBefore),
                '","protectedAmount":"',
                vm.toString(reserveState.protectedAmount),
                '","availableAmount":"',
                vm.toString(reserveState.availableAmount),
                '","revision":"',
                vm.toString(uint256(reserveState.revision)),
                '"}',
                ',"operationId":"',
                vm.toString(operationId),
                '","policyRoot":"',
                vm.toString(policyRoot),
                '","allocationBindingRoot":"',
                vm.toString(allocationBindingRoot),
                '","realizedStatementRoot":"',
                vm.toString(realizedStatementRoot),
                '","configurationRoot":"',
                vm.toString(configRoot0),
                '","configurationEpoch":',
                vm.toString(uint256(configurationEpoch)),
                ',"localOnly":{"sourceVerifierId":"',
                vm.toString(vm.envBytes32("GATE_E_SOURCE_VERIFIER_ID")),
                '","executionVerifierId":"',
                vm.toString(vm.envBytes32("GATE_E_EXECUTION_VERIFIER_ID")),
                '","executionStatementSchema":"',
                vm.toString(vm.envBytes32("GATE_E_EXECUTION_STATEMENT_SCHEMA")),
                '","executionPublicValuesSchema":"',
                vm.toString(vm.envBytes32("GATE_E_EXECUTION_PUBLIC_VALUES_SCHEMA")),
                '","residualRecipient":"',
                vm.toString(vm.envAddress("GATE_E_RESIDUAL_RECIPIENT")),
                '"},"proofStatus":"pending-external-prover","genesisStatus":"bootstrap-coherent"}'
            )
        );
        console2.log("GATE_E_MANIFEST_JSON", root);
    }
}

/// @dev Script-local ERC-20 fixture only; it is not a production token.
contract LocalGateEToken is IERC20 {
    string public constant name = "Gate E local capital";
    string public constant symbol = "GE";
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
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allowance");
        allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
