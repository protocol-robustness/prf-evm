// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPrfChainInstanceGenesis} from "./interfaces/IPrfChainInstanceGenesis.sol";
import {IPrfVerifierRegistry} from "./interfaces/IPrfVerifierRegistry.sol";
import {ISewGovernanceAuthority} from "./interfaces/ISewGovernanceAuthority.sol";

/// @title PrfVerifierRegistry
/// @notice Registry of approved proof verifiers for one PRF chain instance.
///         Mirrors the canonical `:verifier-registry/root` field of
///         `chain-configuration.v1`, mapping verifier identifiers to verifier
///         adapters and pinning the program/ELF identity that each verifier
///         admits.
contract PrfVerifierRegistry is ERC165, IPrfVerifierRegistry {
    bytes32 private constant REGISTRY_DOMAIN =
        keccak256("PRF_VERIFIER_REGISTRY_V1");

    IPrfChainInstanceGenesis public immutable genesis;
    ISewGovernanceAuthority public immutable authority;

    uint256 public verifierCount;

    struct VerifierEntry {
        address adapter;
        bytes32 programVKey;
        bytes32 programElfSha256;
        string programId;
        bytes32 statementSchemaVersionHash;
        bool active;
    }

    mapping(uint256 => VerifierEntry) private _verifiers;
    mapping(address => uint256) public adapterToIndex;
    mapping(bytes32 => uint256) public vkeyToVerifierIndex;

    event VerifierAdded(
        uint256 indexed index,
        address indexed adapter,
        bytes32 programVKey,
        bytes32 programElfSha256,
        string programId
    );

    event VerifierActivated(uint256 indexed index, address indexed adapter);
    event VerifierDeactivated(uint256 indexed index, address indexed adapter);
    event VerifierRemoved(uint256 indexed index, address indexed adapter);

    error GenesisNotSealed();
    error WrongExecutionChain(uint256 expected, uint256 actual);
    error AuthorityMismatch(address expected, address actual);
    error ZeroAddress();
    error ZeroRoot();
    error InvalidIndex();
    error AdapterAlreadyRegistered(address adapter);
    error VkeyAlreadyRegistered(bytes32 programVKey);

    constructor(IPrfChainInstanceGenesis genesis_, ISewGovernanceAuthority authority_) {
        if (!genesis_.isSealedState()) revert GenesisNotSealed();
        if (genesis_.executionChainId() != block.chainid)
            revert WrongExecutionChain(genesis_.executionChainId(), block.chainid);
        if (genesis_.authorityAdapter() != address(authority_))
            revert AuthorityMismatch(genesis_.authorityAdapter(), address(authority_));

        genesis = genesis_;
        authority = authority_;
    }

    function addVerifier(
        address adapter,
        bytes32 programVKey,
        bytes32 programElfSha256,
        string calldata programId,
        bytes32 statementSchemaVersionHash
    ) external onlyAuthority {
        if (adapter == address(0)) revert ZeroAddress();
        if (programVKey == bytes32(0)) revert ZeroRoot();
        if (adapterToIndex[adapter] != 0) revert AdapterAlreadyRegistered(adapter);
        if (vkeyToVerifierIndex[programVKey] != 0) revert VkeyAlreadyRegistered(programVKey);

        uint256 index = verifierCount++;
        _verifiers[index] = VerifierEntry({
            adapter: adapter,
            programVKey: programVKey,
            programElfSha256: programElfSha256,
            programId: programId,
            statementSchemaVersionHash: statementSchemaVersionHash,
            active: true
        });
        adapterToIndex[adapter] = index + 1;
        vkeyToVerifierIndex[programVKey] = index + 1;

        emit VerifierAdded(index, adapter, programVKey, programElfSha256, programId);
    }

    function activateVerifier(uint256 index) external onlyAuthority {
        if (index >= verifierCount) revert InvalidIndex();
        if (_verifiers[index].active) return;
        _verifiers[index].active = true;
        emit VerifierActivated(index, _verifiers[index].adapter);
    }

    function deactivateVerifier(uint256 index) external onlyAuthority {
        if (index >= verifierCount) revert InvalidIndex();
        if (!_verifiers[index].active) return;
        _verifiers[index].active = false;
        emit VerifierDeactivated(index, _verifiers[index].adapter);
    }

    function removeVerifier(uint256 index) external onlyAuthority {
        if (index >= verifierCount) revert InvalidIndex();
        address adapterAddr = _verifiers[index].adapter;
        bytes32 vkey = _verifiers[index].programVKey;
        delete _verifiers[index];
        delete adapterToIndex[adapterAddr];
        vkeyToVerifierIndex[vkey] = 0;
        emit VerifierRemoved(index, adapterAddr);
    }

    function verifiers(uint256 index)
        external
        view
        override
        returns (
            address adapter,
            bytes32 programVKey,
            bytes32 programElfSha256,
            string memory programId,
            bytes32 statementSchemaVersionHash,
            bool active
        )
    {
        VerifierEntry storage v = _verifiers[index];
        return (
            v.adapter,
            v.programVKey,
            v.programElfSha256,
            v.programId,
            v.statementSchemaVersionHash,
            v.active
        );
    }

    function registryRoot() public view override returns (bytes32) {
        bytes32 acc = REGISTRY_DOMAIN;
        for (uint256 i = 0; i < verifierCount; i++) {
            VerifierEntry storage v = _verifiers[i];
            if (v.active) {
                acc = keccak256(abi.encodePacked(acc, v.adapter, v.programVKey, v.programElfSha256, v.programId));
            }
        }
        return acc;
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC165, IERC165)
        returns (bool)
    {
        return
            interfaceId == type(IPrfVerifierRegistry).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    modifier onlyAuthority() {
        if (msg.sender != address(authority) && msg.sender != authority.governor())
            revert AuthorityMismatch(address(authority), msg.sender);
        _;
    }
}
