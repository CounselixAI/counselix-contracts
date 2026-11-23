// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {CounselixRegistry} from "../src/CounselixRegistry.sol";

contract CounselixRegistryTest is Test {
    CounselixRegistry registry;
    address admin = makeAddr("admin");
    address operator = makeAddr("operator");
    address stranger = makeAddr("stranger");
    bytes32 constant HOTKEY = keccak256("miner-1");

    function setUp() public {
        registry = new CounselixRegistry(admin, operator);
    }

    function _education() internal returns (uint32) {
        vm.prank(operator);
        return registry.addCategory("Education");
    }

    function test_AddCategory() public {
        uint32 id = _education();
        assertEq(id, 1);
        CounselixRegistry.Category memory c = registry.getCategory(id);
        assertEq(c.name, "Education");
        assertTrue(c.active);
    }

    function test_RevertWhen_AddCategoryEmptyName() public {
        vm.prank(operator);
        vm.expectRevert(CounselixRegistry.EmptyName.selector);
        registry.addCategory("");
    }

    function test_RevertWhen_StrangerAddsCategory() public {
        bytes32 role = registry.OPERATOR_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role)
        );
        vm.prank(stranger);
        registry.addCategory("Education");
    }

    function test_RegisterAgent() public {
        uint32 cat = _education();
        vm.prank(operator);
        uint256 id = registry.registerAgent(HOTKEY, cat, "ipfs://agent-1");

        assertEq(id, 1);
        assertEq(registry.agentIdOf(HOTKEY, cat), 1);
        CounselixRegistry.Agent memory a = registry.getAgent(id);
        assertEq(a.hotkey, HOTKEY);
        assertEq(a.categoryId, cat);
        assertTrue(a.active);
        assertEq(a.metadataURI, "ipfs://agent-1");
    }

    function test_RevertWhen_RegisterDuplicateAgent() public {
        uint32 cat = _education();
        vm.startPrank(operator);
        registry.registerAgent(HOTKEY, cat, "");
        vm.expectRevert(abi.encodeWithSelector(CounselixRegistry.AgentAlreadyRegistered.selector, HOTKEY, cat, 1));
        registry.registerAgent(HOTKEY, cat, "");
        vm.stopPrank();
    }

    function test_SameHotkeyDifferentCategories() public {
        uint32 edu = _education();
        vm.startPrank(operator);
        uint32 legal = registry.addCategory("Legal");
        assertEq(registry.registerAgent(HOTKEY, edu, ""), 1);
        assertEq(registry.registerAgent(HOTKEY, legal, ""), 2);
        vm.stopPrank();
    }

    function test_RevertWhen_RegisterInInactiveCategory() public {
        uint32 cat = _education();
        vm.startPrank(operator);
        registry.setCategoryActive(cat, false);
        vm.expectRevert(abi.encodeWithSelector(CounselixRegistry.InactiveCategory.selector, cat));
        registry.registerAgent(HOTKEY, cat, "");
        vm.stopPrank();
    }

    function test_RevertWhen_RegisterUnknownCategory() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(CounselixRegistry.UnknownCategory.selector, uint32(7)));
        registry.registerAgent(HOTKEY, 7, "");
    }

    function test_RevertWhen_RegisterZeroHotkey() public {
        uint32 cat = _education();
        vm.prank(operator);
        vm.expectRevert(CounselixRegistry.ZeroHotkey.selector);
        registry.registerAgent(bytes32(0), cat, "");
    }

    function test_UpdateAndDeactivateAgent() public {
        uint32 cat = _education();
        vm.startPrank(operator);
        uint256 id = registry.registerAgent(HOTKEY, cat, "a");
        registry.updateAgentMetadata(id, "b");
        registry.setAgentActive(id, false);
        vm.stopPrank();

        CounselixRegistry.Agent memory a = registry.getAgent(id);
        assertEq(a.metadataURI, "b");
        assertFalse(a.active);
    }

    function test_IsAgentActive() public {
        assertFalse(registry.isAgentActive(1));
        uint32 cat = _education();
        vm.startPrank(operator);
        uint256 id = registry.registerAgent(HOTKEY, cat, "");
        assertTrue(registry.isAgentActive(id));

        registry.setCategoryActive(cat, false);
        assertFalse(registry.isAgentActive(id));
        registry.setCategoryActive(cat, true);
        registry.setAgentActive(id, false);
        assertFalse(registry.isAgentActive(id));
        vm.stopPrank();
    }

    function test_AgentExists() public {
        assertFalse(registry.agentExists(0));
        assertFalse(registry.agentExists(1));
        uint32 cat = _education();
        vm.prank(operator);
        registry.registerAgent(HOTKEY, cat, "");
        assertTrue(registry.agentExists(1));
    }
}
