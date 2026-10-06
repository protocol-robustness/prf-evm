// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {ShortfallV2Commitments} from "../../verification/ShortfallV2Commitments.sol";
import {SourceBoundEntitlementV1Commitments} from "../../verification/SourceBoundEntitlementV1Commitments.sol";

/// @notice Non-exclusive V2 prepared-operation registry.
/// @dev Prepared operations freeze identity only; they reserve zero capital and
/// do not establish a global Shortfall mutex.
contract SourceBoundProRataControllerV2 {
    enum State {
        None,
        Prepared,
        Abandoned,
        Ratified
    }

    struct PreparedOperation {
        bytes32 root;
        address initiator;
        bytes32 operationId;
    }

    mapping(bytes32 => State) public state;
    mapping(bytes32 => bytes32) public preparedOperationRoot;
    mapping(bytes32 => address) public preparedInitiator;
    mapping(bytes32 => bytes32) public preparedConfigurationRoot;
    mapping(bytes32 => uint64) public preparedConfigurationEpoch;
    mapping(bytes32 => uint128) public preparedChainId;
    mapping(bytes32 => address) public preparedReserve;
    mapping(bytes32 => address) public preparedToken;
    mapping(bytes32 => address) public preparedAllocator;
    mapping(bytes32 => bytes32) public preparedResidualRecipient;
    mapping(bytes32 => bytes32) public preparedBeneficiaryProfileWord;
    mapping(bytes32 => bool) public successorEntitlementProfile;
    mapping(bytes32 => bytes32) public preparedSourceVerifierId;
    mapping(bytes32 => bytes32) public preparedSourceProgramVKey;
    mapping(bytes32 => bytes32) public preparedSourceProgramElfSha256;
    mapping(bytes32 => bytes32) public preparedSourceStatementSchema;
    mapping(bytes32 => bytes32) public preparedSourcePublicValuesSchema;

    address public immutable governance;
    address public ratificationController;
    bool public ratificationControllerBound;

    error InvalidOperation();
    error OperationAlreadyExists(bytes32 operationId);
    error OnlyInitiator(address caller);
    error InvalidState(State actual);
    error OnlyGovernance(address caller);
    error RatificationControllerAlreadyBound();
    error OnlyRatificationController(address caller);
    error PreparedRootMismatch();

    event RatificationControllerBound(address indexed controller);
    event OperationPrepared(bytes32 indexed operationId, bytes32 indexed preparedRoot, address indexed initiator);
    event EntitlementOperationPrepared(
        bytes32 indexed operationId, bytes32 indexed preparedRoot, bytes32 beneficiaryProfileWord
    );
    event OperationAbandoned(bytes32 indexed operationId, bytes32 indexed preparedRoot);
    event OperationRatified(bytes32 indexed operationId, bytes32 indexed preparedRoot);

    constructor() {
        governance = msg.sender;
    }

    function bindRatificationController(address controller_) external {
        if (msg.sender != governance) revert OnlyGovernance(msg.sender);
        if (ratificationControllerBound) revert RatificationControllerAlreadyBound();
        if (controller_ == address(0)) revert InvalidOperation();
        ratificationController = controller_;
        ratificationControllerBound = true;
        emit RatificationControllerBound(controller_);
    }

    function finalizePreparedOperation(bytes32 operationId, bytes32 expectedRoot) external {
        if (!ratificationControllerBound || msg.sender != ratificationController) {
            revert OnlyRatificationController(msg.sender);
        }
        if (state[operationId] != State.Prepared) revert InvalidState(state[operationId]);
        if (preparedOperationRoot[operationId] != expectedRoot) revert PreparedRootMismatch();
        state[operationId] = State.Ratified;
        emit OperationRatified(operationId, expectedRoot);
    }

    function prepareOperation(ShortfallV2Commitments.PreparedOperation calldata operation)
        external
        returns (bytes32 root)
    {
        if (operation.operationId == bytes32(0) || operation.initiator == bytes32(0)) {
            revert InvalidOperation();
        }
        address initiator = address(uint160(uint256(operation.initiator)));
        if (initiator == address(0) || msg.sender != initiator) revert OnlyInitiator(msg.sender);
        if (state[operation.operationId] != State.None) revert OperationAlreadyExists(operation.operationId);
        root = ShortfallV2Commitments.preparedOperationRoot(operation);
        preparedOperationRoot[operation.operationId] = root;
        preparedInitiator[operation.operationId] = initiator;
        preparedConfigurationRoot[operation.operationId] = operation.configurationRoot;
        preparedConfigurationEpoch[operation.operationId] = operation.configurationEpoch;
        preparedChainId[operation.operationId] = operation.chainId;
        preparedReserve[operation.operationId] = _canonicalAddress(operation.reserve);
        preparedToken[operation.operationId] = _canonicalAddress(operation.token);
        preparedAllocator[operation.operationId] = _canonicalAddress(operation.allocator);
        preparedResidualRecipient[operation.operationId] = operation.residualRecipient;
        state[operation.operationId] = State.Prepared;
        emit OperationPrepared(operation.operationId, root, initiator);
    }

    /// @notice Additive successor preparation path whose identity commits the
    ///         operation-level beneficiary profile. The legacy V2 root function
    ///         and preparation ABI remain unchanged.
    function prepareEntitlementOperation(SourceBoundEntitlementV1Commitments.PreparedOperation calldata operation)
        external
        returns (bytes32 root)
    {
        if (operation.operationId == bytes32(0) || operation.initiator == address(0)) revert InvalidOperation();
        if (msg.sender != operation.initiator) revert OnlyInitiator(msg.sender);
        if (state[operation.operationId] != State.None) revert OperationAlreadyExists(operation.operationId);
        if (operation.chainId != block.chainid) revert InvalidOperation();
        bytes32 profileWord = SourceBoundEntitlementV1Commitments.beneficiaryProfileWord(operation.beneficiaryProfile);
        root = SourceBoundEntitlementV1Commitments.preparedOperationRoot(operation);
        preparedOperationRoot[operation.operationId] = root;
        preparedInitiator[operation.operationId] = operation.initiator;
        preparedConfigurationRoot[operation.operationId] = operation.configurationRoot;
        if (operation.configurationEpoch > type(uint64).max) revert InvalidOperation();
        preparedConfigurationEpoch[operation.operationId] = uint64(operation.configurationEpoch);
        preparedChainId[operation.operationId] = operation.chainId;
        preparedReserve[operation.operationId] = operation.reserve;
        preparedToken[operation.operationId] = operation.token;
        preparedAllocator[operation.operationId] = operation.allocator;
        preparedResidualRecipient[operation.operationId] = bytes32(uint256(uint160(operation.residualRecipient)));
        preparedBeneficiaryProfileWord[operation.operationId] = profileWord;
        preparedSourceVerifierId[operation.operationId] = operation.sourceVerifierId;
        preparedSourceProgramVKey[operation.operationId] = operation.sourceProgramVKey;
        preparedSourceProgramElfSha256[operation.operationId] = operation.sourceProgramElfSha256;
        preparedSourceStatementSchema[operation.operationId] = operation.sourceStatementSchema;
        preparedSourcePublicValuesSchema[operation.operationId] = operation.sourcePublicValuesSchema;
        successorEntitlementProfile[operation.operationId] = true;
        state[operation.operationId] = State.Prepared;
        emit OperationPrepared(operation.operationId, root, operation.initiator);
        emit EntitlementOperationPrepared(operation.operationId, root, profileWord);
    }

    function _canonicalAddress(bytes32 word) private pure returns (address value) {
        value = address(uint160(uint256(word)));
        if (bytes32(uint256(uint160(value))) != word) revert InvalidOperation();
    }

    function abandonPreparedOperation(bytes32 operationId) external {
        if (state[operationId] != State.Prepared) revert InvalidState(state[operationId]);
        if (msg.sender != preparedInitiator[operationId]) revert OnlyInitiator(msg.sender);
        state[operationId] = State.Abandoned;
        emit OperationAbandoned(operationId, preparedOperationRoot[operationId]);
    }
}
