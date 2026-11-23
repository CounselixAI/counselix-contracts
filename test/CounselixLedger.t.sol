// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {CounselixRegistry} from "../src/CounselixRegistry.sol";
import {CounselixLedger} from "../src/CounselixLedger.sol";

contract CounselixLedgerTest is Test {
    CounselixRegistry registry;
    CounselixLedger ledger;

    address admin = makeAddr("admin");
    address backend = makeAddr("backend");
    address stranger = makeAddr("stranger");

    uint64 constant GENESIS = 1_800_000_000;
    uint64 constant EPOCH = 1 days;
    uint128 constant USD = 1_000_000;

    uint32 edu;
    uint256 agentA;
    uint256 agentB;

    function setUp() public {
        vm.warp(GENESIS);
        registry = new CounselixRegistry(admin, backend);
        ledger = new CounselixLedger(admin, backend, registry, GENESIS, EPOCH);

        vm.startPrank(backend);
        edu = registry.addCategory("Education");
        agentA = registry.registerAgent(keccak256("miner-a"), edu, "");
        agentB = registry.registerAgent(keccak256("miner-b"), edu, "");
        vm.stopPrank();
    }

    function _pay(bytes32 paymentId, bytes32 userId, uint256 agentId, uint128 amount) internal {
        uint64 t = uint64(block.timestamp);
        vm.prank(backend);
        ledger.recordPayment(paymentId, userId, agentId, amount, t, t, t + 30 days);
    }

    function _refund(bytes32 paymentId, uint128 amount) internal {
        vm.prank(backend);
        ledger.recordRefund(paymentId, amount);
    }

    // ------------------------------------------------------------------- epochs

    function test_EpochMath() public {
        assertEq(ledger.currentEpoch(), 0);
        assertFalse(ledger.isEpochClosed(0));
        vm.warp(GENESIS + EPOCH * 3 + 1);
        assertEq(ledger.currentEpoch(), 3);
        assertTrue(ledger.isEpochClosed(2));
        assertFalse(ledger.isEpochClosed(3));
        (uint64 start, uint64 end) = ledger.epochBounds(2);
        assertEq(start, GENESIS + 2 * EPOCH);
        assertEq(end, GENESIS + 3 * EPOCH);
    }

    function test_RevertWhen_ZeroEpochLength() public {
        vm.expectRevert(CounselixLedger.ZeroEpochLength.selector);
        new CounselixLedger(admin, backend, registry, GENESIS, 0);
    }

    function test_RevertWhen_PaymentBeforeGenesis() public {
        CounselixLedger future = new CounselixLedger(admin, backend, registry, GENESIS + 1 days, EPOCH);
        vm.prank(backend);
        vm.expectRevert(CounselixLedger.NotStarted.selector);
        future.recordPayment("pay-1", "user-1", agentA, USD, GENESIS, GENESIS, GENESIS + 1);
    }

    // ----------------------------------------------------------------- payments

    function test_RecordPaymentCreditsSelectedAgent() public {
        _pay("pay-1", "user-1", agentA, 20 * USD);

        CounselixLedger.Payment memory p = ledger.getPayment("pay-1");
        assertEq(p.userId, bytes32("user-1"));
        assertEq(p.agentId, agentA);
        assertEq(p.amount, 20 * USD);
        assertEq(p.epoch, 0);
        assertEq(ledger.paymentCount(), 1);
        assertEq(ledger.totalPaymentVolume(), 20 * USD);

        CounselixLedger.AgentEpochStats memory a = ledger.getAgentEpochStats(0, agentA);
        assertEq(a.revenue, 20 * USD);
        assertEq(a.payments, 1);
        assertEq(a.uniquePayers, 1);
        assertEq(ledger.getAgentEpochStats(0, agentB).revenue, 0);
    }

    function test_EpochFollowsBlockTimeNotPaidAt() public {
        vm.warp(GENESIS + 5 * EPOCH);
        vm.prank(backend);
        // paidAt claims epoch 0, but the payment lands in the current epoch (5).
        ledger.recordPayment("pay-1", "user-1", agentA, USD, GENESIS, GENESIS, GENESIS + 30 days);
        assertEq(ledger.getPayment("pay-1").epoch, 5);
        assertEq(ledger.getAgentEpochStats(0, agentA).revenue, 0);
        assertEq(ledger.getAgentEpochStats(5, agentA).revenue, USD);
    }

    function test_UniquePayersCountsDistinctUsers() public {
        _pay("pay-1", "user-1", agentA, USD);
        _pay("pay-2", "user-1", agentA, USD);
        _pay("pay-3", "user-2", agentA, USD);

        CounselixLedger.AgentEpochStats memory a = ledger.getAgentEpochStats(0, agentA);
        assertEq(a.revenue, 3 * USD);
        assertEq(a.payments, 3);
        assertEq(a.uniquePayers, 2);
    }

    function test_SwitchingMainAgentAppliesToNextPayment() public {
        _pay("pay-1", "user-1", agentA, 20 * USD);
        vm.warp(GENESIS + 30 days);
        _pay("pay-2", "user-1", agentB, 20 * USD);

        assertEq(ledger.getAgentEpochStats(0, agentA).revenue, 20 * USD);
        assertEq(ledger.getAgentEpochStats(30, agentB).revenue, 20 * USD);
        assertEq(ledger.getAgentEpochStats(30, agentA).revenue, 0);
    }

    function test_RevertWhen_DuplicatePayment() public {
        _pay("pay-1", "user-1", agentA, USD);
        vm.prank(backend);
        vm.expectRevert(abi.encodeWithSelector(CounselixLedger.DuplicatePayment.selector, bytes32("pay-1")));
        ledger.recordPayment("pay-1", "user-1", agentA, USD, GENESIS, GENESIS, GENESIS + 1);
    }

    function test_RevertWhen_InvalidPayment() public {
        vm.startPrank(backend);
        vm.expectRevert(CounselixLedger.ZeroAmount.selector);
        ledger.recordPayment("pay-1", "user-1", agentA, 0, GENESIS, GENESIS, GENESIS + 1);
        vm.expectRevert(CounselixLedger.InvalidPeriod.selector);
        ledger.recordPayment("pay-1", "user-1", agentA, USD, GENESIS, GENESIS, GENESIS);
        vm.expectRevert(CounselixLedger.ZeroId.selector);
        ledger.recordPayment(bytes32(0), "user-1", agentA, USD, GENESIS, GENESIS, GENESIS + 1);
        vm.expectRevert(CounselixLedger.ZeroId.selector);
        ledger.recordPayment("pay-1", bytes32(0), agentA, USD, GENESIS, GENESIS, GENESIS + 1);
        vm.stopPrank();
    }

    function test_RevertWhen_PaymentToUnknownAgent() public {
        vm.prank(backend);
        vm.expectRevert(abi.encodeWithSelector(CounselixLedger.AgentNotActive.selector, uint256(99)));
        ledger.recordPayment("pay-1", "user-1", 99, USD, GENESIS, GENESIS, GENESIS + 1);
    }

    function test_RevertWhen_PaymentToInactiveAgent() public {
        vm.prank(backend);
        registry.setAgentActive(agentA, false);
        vm.prank(backend);
        vm.expectRevert(abi.encodeWithSelector(CounselixLedger.AgentNotActive.selector, agentA));
        ledger.recordPayment("pay-1", "user-1", agentA, USD, GENESIS, GENESIS, GENESIS + 1);
    }

    function test_RevertWhen_PaymentToAgentInInactiveCategory() public {
        vm.prank(backend);
        registry.setCategoryActive(edu, false);
        vm.prank(backend);
        vm.expectRevert(abi.encodeWithSelector(CounselixLedger.AgentNotActive.selector, agentA));
        ledger.recordPayment("pay-1", "user-1", agentA, USD, GENESIS, GENESIS, GENESIS + 1);
    }

    function test_RevertWhen_StrangerRecordsPayment() public {
        bytes32 role = ledger.RECORDER_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role)
        );
        vm.prank(stranger);
        ledger.recordPayment("pay-1", "user-1", agentA, USD, GENESIS, GENESIS, GENESIS + 1);
    }

    // ------------------------------------------------------------------ refunds

    function test_RefundBookedInCurrentEpoch() public {
        _pay("pay-1", "user-1", agentA, 20 * USD);
        vm.warp(GENESIS + 2 * EPOCH);
        _refund("pay-1", 5 * USD);
        _refund("pay-1", 15 * USD);

        // Original epoch is untouched.
        CounselixLedger.AgentEpochStats memory e0 = ledger.getAgentEpochStats(0, agentA);
        assertEq(e0.revenue, 20 * USD);
        assertEq(e0.refunded, 0);
        // Refund lands in the epoch it happened in, against the same agent.
        CounselixLedger.AgentEpochStats memory e2 = ledger.getAgentEpochStats(2, agentA);
        assertEq(e2.revenue, 0);
        assertEq(e2.refunded, 20 * USD);
        assertEq(ledger.getEpochSummary(2).agentCount, 1);

        assertEq(ledger.getPayment("pay-1").refunded, 20 * USD);
        assertEq(ledger.totalRefundVolume(), 20 * USD);
    }

    function test_RevertWhen_RefundExceedsPayment() public {
        _pay("pay-1", "user-1", agentA, 20 * USD);
        _refund("pay-1", 15 * USD);
        vm.prank(backend);
        vm.expectRevert(
            abi.encodeWithSelector(CounselixLedger.RefundExceedsPayment.selector, bytes32("pay-1"), 5 * USD)
        );
        ledger.recordRefund("pay-1", 6 * USD);
    }

    function test_RevertWhen_InvalidRefund() public {
        vm.startPrank(backend);
        vm.expectRevert(abi.encodeWithSelector(CounselixLedger.UnknownPayment.selector, bytes32("nope")));
        ledger.recordRefund("nope", USD);
        vm.expectRevert(CounselixLedger.ZeroAmount.selector);
        ledger.recordRefund("nope", 0);
        vm.stopPrank();
    }

    function test_RefundAllowedAfterAgentDeactivated() public {
        _pay("pay-1", "user-1", agentA, USD);
        vm.prank(backend);
        registry.setAgentActive(agentA, false);
        _refund("pay-1", USD);
        assertEq(ledger.getAgentEpochStats(0, agentA).refunded, USD);
    }

    // ---------------------------------------------------------------- validators

    function test_EpochAttribution() public {
        _pay("pay-1", "user-1", agentA, 20 * USD);
        _pay("pay-2", "user-2", agentA, 20 * USD);
        _pay("pay-3", "user-3", agentB, 10 * USD);
        vm.warp(GENESIS + EPOCH);

        (
            uint256[] memory ids,
            uint128[] memory revenues,
            uint128[] memory refunds,
            uint32[] memory payments,
            uint32[] memory payers
        ) = ledger.getEpochAttribution(0);
        assertEq(ids.length, 2);
        assertEq(ids[0], agentA);
        assertEq(revenues[0], 40 * USD);
        assertEq(refunds[0], 0);
        assertEq(payments[0], 2);
        assertEq(payers[0], 2);
        assertEq(ids[1], agentB);
        assertEq(revenues[1], 10 * USD);

        CounselixLedger.EpochSummary memory s = ledger.getEpochSummary(0);
        assertEq(s.revenue, 50 * USD);
        assertEq(s.payments, 3);
        assertEq(s.agentCount, 2);
    }

    function test_EmptyClosedEpoch() public {
        vm.warp(GENESIS + EPOCH);
        (uint256[] memory ids,,,,) = ledger.getEpochAttribution(0);
        assertEq(ids.length, 0);
    }

    function test_RevertWhen_ReadingOpenEpoch() public {
        vm.expectRevert(abi.encodeWithSelector(CounselixLedger.EpochNotClosed.selector, uint64(0)));
        ledger.getEpochAttribution(0);
    }

    function testFuzz_RevenueConserved(uint128 a, uint128 b, uint128 refundA) public {
        a = uint128(bound(a, 1, 1e15));
        b = uint128(bound(b, 1, 1e15));
        refundA = uint128(bound(refundA, 0, a));
        _pay("pay-a", "user-1", agentA, a);
        _pay("pay-b", "user-2", agentB, b);
        if (refundA > 0) _refund("pay-a", refundA);

        CounselixLedger.EpochSummary memory s = ledger.getEpochSummary(0);
        assertEq(s.revenue, a + b);
        assertEq(s.refunded, refundA);
        assertEq(ledger.getAgentEpochStats(0, agentA).revenue + ledger.getAgentEpochStats(0, agentB).revenue, s.revenue);
    }
}
