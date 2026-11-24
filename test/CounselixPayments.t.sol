// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {CounselixRegistry} from "../src/CounselixRegistry.sol";
import {CounselixLedger} from "../src/CounselixLedger.sol";
import {CounselixTaoPayments} from "../src/CounselixTaoPayments.sol";
import {CounselixUsdcPayments} from "../src/CounselixUsdcPayments.sol";
import {Plan} from "../src/Plan.sol";
import {MockERC20, MockOracle, RejectingPayer} from "./mocks/Mocks.sol";

contract CounselixTaoPaymentsTest is Test {
    CounselixRegistry registry;
    CounselixLedger ledger;
    CounselixTaoPayments payments;
    MockOracle oracle;

    address admin = makeAddr("admin");
    address backend = makeAddr("backend");
    address treasury = makeAddr("treasury");
    address user = makeAddr("user");

    uint64 constant GENESIS = 1_800_057_600;
    uint128 constant USD = 1_000_000;
    uint256 agentId;

    function setUp() public {
        vm.warp(GENESIS);
        registry = new CounselixRegistry(admin, backend);
        ledger = new CounselixLedger(admin, registry, GENESIS);
        oracle = new MockOracle(200 * USD); // $200 per TAO
        payments = new CounselixTaoPayments(admin, ledger, oracle, treasury, 20 * USD, 200 * USD);
        vm.startPrank(admin);
        ledger.grantRole(ledger.PAYMENTS_ROLE(), address(payments));
        vm.stopPrank();

        vm.startPrank(backend);
        uint32 edu = registry.addCategory("Education");
        agentId = registry.registerAgent(keccak256("miner-a"), edu, "");
        vm.stopPrank();
        vm.deal(user, 100 ether);
    }

    function test_Quote() public view {
        (uint256 taoAmount, uint256 price) = payments.quote(Plan.Monthly);
        assertEq(price, 200 * USD);
        assertEq(taoAmount, 0.1 ether); // $20 / $200
        (taoAmount,) = payments.quote(Plan.Annual);
        assertEq(taoAmount, 1 ether);
    }

    function test_QuoteRoundsUp() public {
        oracle.setPrice(3 * USD); // $20 / $3 = 6.666... TAO
        (uint256 taoAmount,) = payments.quote(Plan.Monthly);
        assertEq(taoAmount, 6_666_666_666_666_666_667);
    }

    function test_PayForwardsToTreasuryRecordsAndRefundsExcess() public {
        vm.prank(user);
        payments.pay{value: 0.15 ether}("pay-1", "user-1", agentId, Plan.Monthly);

        assertEq(treasury.balance, 0.1 ether);
        assertEq(user.balance, 100 ether - 0.1 ether);
        assertEq(address(payments).balance, 0);

        CounselixLedger.Payment memory p = ledger.getPayment("pay-1");
        assertEq(p.usdAmount, 20 * USD);
        assertEq(p.tokenAmount, 0.1 ether);
        assertEq(p.taoUsdPrice, 200 * USD);
        assertEq(p.payer, user);
        assertEq(p.agentId, agentId);
        assertEq(ledger.totalPaidUsd(), 20 * USD);
    }

    function test_RevertWhen_Underpaid() public {
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(CounselixTaoPayments.InsufficientPayment.selector, 0.1 ether, 0.09 ether)
        );
        payments.pay{value: 0.09 ether}("pay-1", "user-1", agentId, Plan.Monthly);
    }

    function test_RevertWhen_AgentInactive() public {
        vm.prank(backend);
        registry.setAgentActive(agentId, false);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(CounselixLedger.AgentNotActive.selector, agentId));
        payments.pay{value: 0.1 ether}("pay-1", "user-1", agentId, Plan.Monthly);
    }

    function test_RevertWhen_DuplicatePaymentId() public {
        vm.startPrank(user);
        payments.pay{value: 0.1 ether}("pay-1", "user-1", agentId, Plan.Monthly);
        vm.expectRevert(abi.encodeWithSelector(CounselixLedger.DuplicatePayment.selector, bytes32("pay-1")));
        payments.pay{value: 0.1 ether}("pay-1", "user-1", agentId, Plan.Monthly);
        vm.stopPrank();
    }

    function test_RevertWhen_PlanNotPriced() public {
        vm.prank(admin);
        payments.setPlanPrice(Plan.Annual, 0);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(CounselixTaoPayments.PlanNotPriced.selector, Plan.Annual));
        payments.pay{value: 1 ether}("pay-1", "user-1", agentId, Plan.Annual);
    }

    function test_RevertWhen_RefundRejected() public {
        RejectingPayer rejecting = new RejectingPayer();
        vm.deal(address(rejecting), 1 ether);
        bytes memory data = abi.encodeCall(CounselixTaoPayments.pay, ("pay-1", "user-1", agentId, Plan.Monthly));
        vm.expectRevert(CounselixTaoPayments.TransferFailed.selector);
        rejecting.pay{value: 0.2 ether}(address(payments), data);
        // Exact amount needs no refund and succeeds.
        rejecting.pay{value: 0.1 ether}(address(payments), data);
        assertEq(treasury.balance, 0.1 ether);
    }

    function test_AdminSetters() public {
        address newTreasury = makeAddr("new-treasury");
        MockOracle newOracle = new MockOracle(100 * USD);
        vm.startPrank(admin);
        payments.setTreasury(newTreasury);
        payments.setOracle(newOracle);
        payments.setPlanPrice(Plan.Monthly, 30 * USD);
        vm.stopPrank();
        (uint256 taoAmount,) = payments.quote(Plan.Monthly);
        assertEq(taoAmount, 0.3 ether);

        vm.prank(user);
        payments.pay{value: 0.3 ether}("pay-1", "user-1", agentId, Plan.Monthly);
        assertEq(newTreasury.balance, 0.3 ether);

        bytes32 role = payments.DEFAULT_ADMIN_ROLE();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, role));
        vm.prank(user);
        payments.setTreasury(user);
    }

    function testFuzz_TreasuryReceivesExactQuote(uint256 price, uint256 extra) public {
        price = bound(price, 1 * USD, 100_000 * USD);
        extra = bound(extra, 0, 1 ether);
        oracle.setPrice(price);
        (uint256 taoAmount,) = payments.quote(Plan.Monthly);
        vm.deal(user, taoAmount + extra);
        vm.prank(user);
        payments.pay{value: taoAmount + extra}("pay-1", "user-1", agentId, Plan.Monthly);
        assertEq(treasury.balance, taoAmount);
        assertEq(user.balance, extra);
        // Treasury value at the recorded price covers the USD price.
        assertGe(taoAmount * price / 1e18 + 1, 20 * USD);
    }
}

contract CounselixUsdcPaymentsTest is Test {
    CounselixUsdcPayments payments;
    MockERC20 usdc;

    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address user = makeAddr("user");
    uint128 constant USD = 1_000_000;

    function setUp() public {
        usdc = new MockERC20("USDC", 6);
        payments = new CounselixUsdcPayments(admin, usdc, treasury, 20 * USD, 200 * USD);
        usdc.mint(user, 1000 * USD);
        vm.prank(user);
        usdc.approve(address(payments), type(uint256).max);
    }

    function test_PayMovesUsdcToTreasuryAndEmits() public {
        vm.expectEmit(address(payments));
        emit CounselixUsdcPayments.UsdcPaymentReceived("pay-1", "user-1", 7, Plan.Annual, user, 200 * USD);
        vm.prank(user);
        payments.pay("pay-1", "user-1", 7, Plan.Annual);
        assertEq(usdc.balanceOf(treasury), 200 * USD);
        assertEq(usdc.balanceOf(address(payments)), 0);
        assertTrue(payments.isPaid("pay-1"));
    }

    function test_RevertWhen_DuplicatePayment() public {
        vm.startPrank(user);
        payments.pay("pay-1", "user-1", 7, Plan.Monthly);
        vm.expectRevert(abi.encodeWithSelector(CounselixUsdcPayments.DuplicatePayment.selector, bytes32("pay-1")));
        payments.pay("pay-1", "user-1", 7, Plan.Monthly);
        vm.stopPrank();
    }

    function test_RevertWhen_NoAllowance() public {
        address other = makeAddr("other");
        usdc.mint(other, 100 * USD);
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(payments), 0, 20 * USD)
        );
        payments.pay("pay-1", "user-1", 7, Plan.Monthly);
    }

    function test_RevertWhen_InvalidInput() public {
        vm.startPrank(user);
        vm.expectRevert(CounselixUsdcPayments.ZeroId.selector);
        payments.pay(bytes32(0), "user-1", 7, Plan.Monthly);
        vm.stopPrank();
        vm.prank(admin);
        payments.setPlanPrice(Plan.Monthly, 0);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(CounselixUsdcPayments.PlanNotPriced.selector, Plan.Monthly));
        payments.pay("pay-1", "user-1", 7, Plan.Monthly);
    }

    function test_AdminSetTreasury() public {
        address newTreasury = makeAddr("new-treasury");
        vm.prank(admin);
        payments.setTreasury(newTreasury);
        vm.prank(user);
        payments.pay("pay-1", "user-1", 7, Plan.Monthly);
        assertEq(usdc.balanceOf(newTreasury), 20 * USD);
    }
}
