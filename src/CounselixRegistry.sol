// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title CounselixRegistry
/// @notice Registry of consulting categories and the miner-operated AI agents offered in each.
/// @dev Agents are keyed by the miner's Bittensor hotkey (32-byte sr25519 public key). The
///      operator (platform backend) registers agents after verifying hotkey ownership off-chain.
///      Validators map hotkey -> UID via the subnet metagraph; UIDs are not stored because they
///      can be recycled.
contract CounselixRegistry is AccessControl {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    struct Category {
        string name;
        bool active;
    }

    struct Agent {
        bytes32 hotkey;
        uint32 categoryId;
        bool active;
        uint64 registeredAt;
        string metadataURI;
    }

    /// @notice Number of categories created. Category IDs are 1..categoryCount.
    uint32 public categoryCount;
    /// @notice Number of agents registered. Agent IDs are 1..agentCount.
    uint256 public agentCount;

    mapping(uint32 => Category) private _categories;
    mapping(uint256 => Agent) private _agents;
    /// @notice One agent per (hotkey, category). Returns 0 if none.
    mapping(bytes32 => mapping(uint32 => uint256)) public agentIdOf;

    event CategoryAdded(uint32 indexed categoryId, string name);
    event CategoryStatusChanged(uint32 indexed categoryId, bool active);
    event AgentRegistered(uint256 indexed agentId, bytes32 indexed hotkey, uint32 indexed categoryId, string metadataURI);
    event AgentMetadataUpdated(uint256 indexed agentId, string metadataURI);
    event AgentStatusChanged(uint256 indexed agentId, bool active);

    error EmptyName();
    error ZeroHotkey();
    error UnknownCategory(uint32 categoryId);
    error InactiveCategory(uint32 categoryId);
    error UnknownAgent(uint256 agentId);
    error AgentAlreadyRegistered(bytes32 hotkey, uint32 categoryId, uint256 agentId);

    constructor(address admin, address operator) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, operator);
    }

    // ---------------------------------------------------------------- categories

    function addCategory(string calldata name) external onlyRole(OPERATOR_ROLE) returns (uint32 categoryId) {
        if (bytes(name).length == 0) revert EmptyName();
        categoryId = ++categoryCount;
        _categories[categoryId] = Category({name: name, active: true});
        emit CategoryAdded(categoryId, name);
    }

    function setCategoryActive(uint32 categoryId, bool active) external onlyRole(OPERATOR_ROLE) {
        _requireCategory(categoryId);
        _categories[categoryId].active = active;
        emit CategoryStatusChanged(categoryId, active);
    }

    function getCategory(uint32 categoryId) external view returns (Category memory) {
        _requireCategory(categoryId);
        return _categories[categoryId];
    }

    // -------------------------------------------------------------------- agents

    function registerAgent(bytes32 hotkey, uint32 categoryId, string calldata metadataURI)
        external
        onlyRole(OPERATOR_ROLE)
        returns (uint256 agentId)
    {
        if (hotkey == bytes32(0)) revert ZeroHotkey();
        _requireCategory(categoryId);
        if (!_categories[categoryId].active) revert InactiveCategory(categoryId);
        uint256 existing = agentIdOf[hotkey][categoryId];
        if (existing != 0) revert AgentAlreadyRegistered(hotkey, categoryId, existing);

        agentId = ++agentCount;
        _agents[agentId] = Agent({
            hotkey: hotkey,
            categoryId: categoryId,
            active: true,
            registeredAt: uint64(block.timestamp),
            metadataURI: metadataURI
        });
        agentIdOf[hotkey][categoryId] = agentId;
        emit AgentRegistered(agentId, hotkey, categoryId, metadataURI);
    }

    function updateAgentMetadata(uint256 agentId, string calldata metadataURI) external onlyRole(OPERATOR_ROLE) {
        _requireAgent(agentId);
        _agents[agentId].metadataURI = metadataURI;
        emit AgentMetadataUpdated(agentId, metadataURI);
    }

    function setAgentActive(uint256 agentId, bool active) external onlyRole(OPERATOR_ROLE) {
        _requireAgent(agentId);
        _agents[agentId].active = active;
        emit AgentStatusChanged(agentId, active);
    }

    function getAgent(uint256 agentId) external view returns (Agent memory) {
        _requireAgent(agentId);
        return _agents[agentId];
    }

    function agentExists(uint256 agentId) public view returns (bool) {
        return agentId != 0 && agentId <= agentCount;
    }

    // ------------------------------------------------------------------ internal

    function _requireCategory(uint32 categoryId) private view {
        if (categoryId == 0 || categoryId > categoryCount) revert UnknownCategory(categoryId);
    }

    function _requireAgent(uint256 agentId) private view {
        if (!agentExists(agentId)) revert UnknownAgent(agentId);
    }
}
