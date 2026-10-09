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

/// @notice Gate E deployment producer for the existing V2 production-shaped
/// capital topology. It does not deploy or synthesize canonical admission,
/// genesis, configuration, verifier, or proof identities.
contract DeployGateE is Script {
    uint256 internal constant INITIAL_CAPITAL = 100;
    uint256 internal constant PROTECTED_CAPITAL = 10;

    function run()
        external
        returns (address token, address reserve, address allocator, bytes32 preparedRoot, bytes32 reserveCommitment)
    {
        uint256 key = vm.envUint("PRIVATE_KEY");
        bytes32 protocolRoot = vm.envBytes32("GATE_E_PROTOCOL_GENESIS_ROOT");
        bytes32 authorityStateRoot = vm.envBytes32("GATE_E_AUTHORITY_STATE_ROOT");
        bytes32 chainInstanceRoot = vm.envBytes32("GATE_E_CHAIN_INSTANCE_GENESIS_ROOT");
        bytes32 configurationRoot0 = vm.envBytes32("GATE_E_CONFIGURATION_ROOT_0");
        bytes32 configurationRoot = vm.envBytes32("GATE_E_CONFIGURATION_ROOT_1");
        bytes32 decisionRoot = vm.envBytes32("GATE_E_DECISION_ROOT");
        bytes32 sourceProgramVKey = vm.envBytes32("GATE_E_SOURCE_PROGRAM_VKEY");
        bytes32 sourceProgramElfSha256 = vm.envBytes32("GATE_E_SOURCE_PROGRAM_ELF_SHA256");
        uint64 configurationEpoch = uint64(vm.envUint("GATE_E_CONFIGURATION_EPOCH"));
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

        vm.startBroadcast(key);
        address authority = vm.addr(key);

        SewGovernanceAuthorityAdapter authorityAdapter =
            new SewGovernanceAuthorityAdapter(protocolRoot, authority, authorityStateRoot);
        PrfChainInstanceGenesis genesis = new PrfChainInstanceGenesis(
            protocolRoot, block.chainid, 1, address(authorityAdapter), authorityStateRoot, configurationRoot0, authority
        );
        genesis.sealGenesis(chainInstanceRoot, address(genesis).codehash, address(authorityAdapter).codehash);
        SP1Verifier sp1Verifier = new SP1Verifier();
        PrfSourceBoundStatementVerifierAdapterV2 sourceAdapter = new PrfSourceBoundStatementVerifierAdapterV2(
            ISP1Verifier(address(sp1Verifier)), sourceProgramVKey, sourceProgramElfSha256
        );
        PrfVerifierRegistry verifierRegistry = new PrfVerifierRegistry(authority);
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
        bytes32 registryRoot =
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
            registryRoot, ids[0], adapters[0], vkeys[0], elfs[0], programIds[0], schemas[0], pvSchemas[0]
        );
        verifierRegistry.sealRegistry(registryRoot);
        SewConfigurationExecutor executor =
            new SewConfigurationExecutor(genesis, authorityAdapter, verifierRegistry, registryRoot0);
        authorityAdapter.authoriseDecision(
            decisionRoot,
            0,
            chainInstanceRoot,
            configurationRoot0,
            configurationRoot,
            registryRoot0,
            registryRoot,
            configurationEpoch
        );
        executor.applyConfiguration(
            decisionRoot, configurationRoot, registryRoot, configurationEpoch, 0, chainInstanceRoot, new bytes32[](0)
        );
        PrfStatementAdmission admission =
            new PrfStatementAdmission(genesis, executor, verifierRegistry, configurationRoot, configurationEpoch);

        LocalGateEToken gateToken = new LocalGateEToken(authority, INITIAL_CAPITAL);
        ProductionProRataAllocatorV2 deployedAllocator = new ProductionProRataAllocatorV2(authority, executor);
        OnchainShortfallReserveV2 deployedReserve =
            new OnchainShortfallReserveV2(IERC20(address(gateToken)), authority, PROTECTED_CAPITAL, deployedAllocator);
        SourceBoundProRataControllerV2 preparedController = new SourceBoundProRataControllerV2();
        SourceBoundProRataAssuranceV2 assurance = new SourceBoundProRataAssuranceV2(
            IPrfStatementAdmission(address(admission)), sourceAdapter, preparedController, authority
        );
        SourceBoundProRataRatificationControllerV2 ratification =
            new SourceBoundProRataRatificationControllerV2(preparedController, assurance, deployedReserve);

        preparedController.bindRatificationController(address(ratification));
        deployedAllocator.bindFundingAuthority(address(deployedReserve));
        deployedReserve.bindRatificationAuthority(address(ratification));
        assurance.bindRatificationController(address(ratification));
        require(
            address(sp1Verifier) != address(0) && address(sourceAdapter) != address(0), "Gate E: verifier deployment"
        );
        require(
            address(verifierRegistry) != address(0) && address(admission) != address(0), "Gate E: admission deployment"
        );
        require(verifierRegistry.governor() == authority, "Gate E: registry governor");
        require(address(sourceAdapter.sp1Verifier()) == address(sp1Verifier), "Gate E: adapter verifier");
        require(deployedAllocator.fundingAuthority() == address(deployedReserve), "Gate E: allocator binding");
        require(deployedReserve.ratificationAuthority() == address(ratification), "Gate E: reserve binding");
        require(
            preparedController.ratificationController() == address(ratification), "Gate E: prepared controller binding"
        );
        require(assurance.ratificationController() == address(ratification), "Gate E: assurance binding");
        require(address(admission.verifierRegistry()) == address(verifierRegistry), "Gate E: admission registry");

        ShortfallV2Commitments.PreparedOperation memory operation = ShortfallV2Commitments.PreparedOperation({
            operationId: operationId,
            initiator: bytes32(uint256(uint160(authority))),
            chainId: uint64(block.chainid),
            reserve: bytes32(uint256(uint160(address(deployedReserve)))),
            token: bytes32(uint256(uint160(address(gateToken)))),
            allocator: bytes32(uint256(uint160(address(deployedAllocator)))),
            configurationRoot: configurationRoot,
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
        // Establish the live reserve basis through the production commitment path.
        IERC20(address(gateToken)).approve(address(deployedReserve), INITIAL_CAPITAL);
        deployedReserve.deposit(INITIAL_CAPITAL);
        reserveCommitment = deployedReserve.economicState(preparedRoot).commitment;

        // This is the deterministic pre-funding basis. No proof is fabricated
        // and no assurance is prepared until a real admission receipt exists.
        vm.stopBroadcast();

        token = address(gateToken);
        reserve = address(deployedReserve);
        allocator = address(deployedAllocator);
        _writeManifest(
            token,
            reserve,
            allocator,
            address(preparedController),
            address(assurance),
            address(ratification),
            preparedRoot,
            reserveCommitment,
            address(admission),
            address(sourceAdapter),
            configurationRoot,
            configurationEpoch,
            operationId,
            policyRoot,
            allocationBindingRoot,
            realizedStatementRoot
        );
        console2.log("GATE_E_MANIFEST_JSON emitted above; persist only to an absent/new output path");
    }

    function _writeManifest(
        address token,
        address reserve,
        address allocator,
        address preparedController,
        address assurance,
        address ratification,
        bytes32 preparedRoot,
        bytes32 reserveCommitment,
        address admission,
        address sourceAdapter,
        bytes32 configurationRoot,
        uint64 configurationEpoch,
        bytes32 operationId,
        bytes32 policyRoot,
        bytes32 allocationBindingRoot,
        bytes32 realizedStatementRoot
    ) private {
        string memory root = string(
            abi.encodePacked(
                '{"schema":"prf-evm.gate-e-deployment.v1","chainId":',
                vm.toString(block.chainid),
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
                '"},"deploymentTxs":[],"preparedOperationRoot":"',
                vm.toString(preparedRoot),
                '"reserveStateCommitment":"',
                vm.toString(reserveCommitment),
                '"operationId":"',
                vm.toString(operationId),
                '"policyRoot":"',
                vm.toString(policyRoot),
                '"allocationBindingRoot":"',
                vm.toString(allocationBindingRoot),
                '","realizedStatementRoot":"',
                vm.toString(realizedStatementRoot),
                '","configurationRoot":"',
                vm.toString(configurationRoot),
                '","configurationEpoch":',
                vm.toString(uint256(configurationEpoch)),
                ',"deploymentTxsNote":"Recover deployment transaction hashes from broadcast JSON; Forge does not expose them in-script.",',
                '"proofStatus":"pending-external-prover","genesisStatus":"externally-supplied"}'
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
