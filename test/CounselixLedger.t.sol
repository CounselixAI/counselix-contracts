// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {CounselixRegistry} from "../src/CounselixRegistry.sol";
import {CounselixLedger} from "../src/CounselixLedger.sol";
import {Plan} from "../src/Plan.sol";

contract CounselixLedgerTest is Test {
    CounselixRegistry registry;
    CounselixLedger ledger;

    address admin = makeAddr("admin");
    address backend = makeAddr("backend");
    address payments = makeAddr("payments");
    address payer = makeAddr("payer");
    address stranger = makeAddr("stranger");

    uint64 constant GENESIS = 1_800_057_600; // a UTC midnight
    uint64 constant DAY = 1 days;
    uint128 constant USD = 1_000_000;
    uint128 constant TAO = 1e18;

    uint32 edu;
    uint256 agentA;
    uint256 agentB;

    function setUp() public {
        vm.warp(GENESIS);
        registry = new CounselixRegistry(admin, backend);
        ledger = new CounselixLedger(admin, registry, GENESIS);

        vm.startPrank(admin);
        ledger.grantRole(ledger.PAYMENTS_ROLE(), payments);
        ledger.grantRole(ledger.RELAYER_ROLE(), backend);
        ledger.grantRole(ledger.RECORDER_ROLE(), backend);
        vm.stopPrank();

        vm.startPrank(backend);
        edu = registry.addCategory("Education");
        agentA = registry.registerAgent(keccak256("miner-a"), edu, "");
        agentB = registry.registerAgent(keccak256("miner-b"), edu, "");
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ helpers

    function _payTao(bytes32 id, uint128 usd) internal {
        vm.prank(payments);
        ledger.recordTaoPayment(id, "user-1", agentA, Plan.Monthly, payer, usd, 1 * TAO, 180 * USD);
    }

    function _relayUsdc(bytes32 id, uint128 usd, bytes32 txHash, uint32 logIndex) internal {
        vm.prank(backend);
        ledger.recordBaseUsdcPayment(id, "user-2", agentB, Plan.Annual, payer, usd, GENESIS, txHash, logIndex);
    }

    function _submit(uint64 day, uint256 a, uint128 ra, uint256 b, uint128 rb) internal {
        uint256[] memory ids = new uint256[](2);
        uint128[] memory amounts = new uint128[](2);
        (ids[0], ids[1], amounts[0], amounts[1]) = (a, b, ra, rb);
        vm.prank(backend);
        ledger.submitDailyRevenue(day, ids, amounts, keccak256("root"));
    }

    // --------------------------------------------------------------------- days

    function test_DayMath() public {
        assertEq(ledger.currentDay(), 0);
        assertFalse(ledger.isDayClosed(0));
        vm.warp(GENESIS + 3 * DAY + 1);
        assertEq(ledger.currentDay(), 3);
        assertTrue(ledger.isDayClosed(2));
        (uint64 start, uint64 end) = ledger.dayBounds(2);
        assertEq(start, GENESIS + 2 * DAY);
        assertEq(end, GENESIS + 3 * DAY);
    }

    function test_RevertWhen_GenesisNotMidnight() public {
        vm.expectRevert(abi.encodeWithSelector(CounselixLedger.GenesisNotMidnight.selector, GENESIS + 1));
        new CounselixLedger(admin, registry, GENESIS + 1);
    }

    // ----------------------------------------------------------------- payments

    function test_RecordTaoPayment() public {
        _payTao("pay-1", 20 * USD);
        CounselixLedger.Payment memory p = ledger.getPayment("pay-1");
        assertEq(p.userId, bytes32("user-1"));
        assertEq(p.agentId, agentA);
        assertEq(uint8(p.source), uint8(CounselixLedger.Source.Tao));
        assertEq(p.payer, payer);
        assertEq(p.usdAmount, 20 * USD);
        assertEq(p.tokenAmount, TAO);
        assertEq(p.taoUsdPrice, 180 * USD);
        assertEq(p.paidAt, GENESIS);
        assertEq(ledger.totalPaidUsd(), 20 * USD);
        assertEq(ledger.paymentCount(), 1);
    }

    function test_RelayBaseUsdcPayment() public {
        _relayUsdc("pay-2", 200 * USD, keccak256("base-tx"), 3);
        CounselixLedger.Payment memory p = ledger.getPayment("pay-2");
        assertEq(uint8(p.source), uint8(CounselixLedger.Source.BaseUsdc));
        assertEq(uint8(p.plan), uint8(Plan.Annual));
        assertEq(p.usdAmount, 200 * USD);
        assertEq(p.tokenAmount, 200 * USD);
        assertEq(p.sourceTxHash, keccak256("base-tx"));
        assertEq(p.sourceLogIndex, 3);
    }

    function test_RevertWhen_DuplicatePaymentOrRelay() public {
        _payTao("pay-1", USD);
        vm.prank(payments);
        vm.expectRevert(abi.encodeWithSelector(CounselixLedger.DuplicatePayment.selector, bytes32("pay-1")));
        ledger.recordTaoPayment("pay-1", "user-1", agentA, Plan.Monthly, payer, USD, TAO, USD);

        _relayUsdc("pay-2", USD, keccak256("tx"), 0);
        vm.prank(backend);
        vm.expectRevert(abi.encodeWithSelector(CounselixLedger.DuplicateRelay.selector, keccak256("tx"), uint32(0)));
        ledger.recordBaseUsdcPayment("pay-3", "user-2", agentB, Plan.Monthly, payer, USD, GENESIS, keccak256("tx"), 0);
    }

    function test_RevertWhen_TaoPaymentForInactiveAgent() public {
        vm.prank(backend);
        registry.setAgentActive(agentA, false);
        vm.prank(payments);
        vm.expectRevert(abi.encodeWithSelector(CounselixLedger.AgentNotActive.selector, agentA));
        ledger.recordTaoPayment("pay-1", "user-1", agentA, Plan.Monthly, payer, USD, TAO, USD);
    }

    function test_RelayAllowedForInactiveAgent() public {
        // The USDC was already paid on Base; it must still be recorded.
        vm.prank(backend);
        registry.setAgentActive(agentB, false);
        _relayUsdc("pay-2", USD, keccak256("tx"), 0);
        assertEq(ledger.totalPaidUsd(), USD);
    }

    function test_RevertWhen_InvalidPayment() public {
        vm.startPrank(payments);
        vm.expectRevert(CounselixLedger.ZeroId.selector);
        ledger.recordTaoPayment(bytes32(0), "user-1", agentA, Plan.Monthly, payer, USD, TAO, USD);
        vm.expectRevert(CounselixLedger.ZeroAmount.selector);
        ledger.recordTaoPayment("pay-1", "user-1", agentA, Plan.Monthly, payer, 0, TAO, USD);
        vm.expectRevert(CounselixLedger.ZeroAmount.selector);
        ledger.recordTaoPayment("pay-1", "user-1", agentA, Plan.Monthly, payer, USD, 0, USD);
        vm.expectRevert(CounselixLedger.ZeroAddress.selector);
        ledger.recordTaoPayment("pay-1", "user-1", agentA, Plan.Monthly, address(0), USD, TAO, USD);
        vm.stopPrank();
    }

    function test_RevertWhen_WrongRoles() public {
        bytes32 paymentsRole = ledger.PAYMENTS_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, backend, paymentsRole)
        );
        vm.prank(backend);
        ledger.recordTaoPayment("pay-1", "user-1", agentA, Plan.Monthly, payer, USD, TAO, USD);

        bytes32 relayerRole = ledger.RELAYER_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, relayerRole)
        );
        vm.prank(stranger);
        ledger.recordBaseUsdcPayment("pay-2", "user-2", agentB, Plan.Monthly, payer, USD, GENESIS, "tx", 0);

        bytes32 recorderRole = ledger.RECORDER_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, recorderRole)
        );
        vm.prank(stranger);
        ledger.heartbeat();
    }

    // ------------------------------------------------------------ daily revenue

    function test_SubmitDailyRevenue() public {
        _payTao("pay-1", 30 * USD);
        vm.warp(GENESIS + DAY);
        _submit(0, agentA, 2 * USD, agentB, USD / 2);

        CounselixLedger.DayRecord memory d = ledger.getDay(0);
        assertTrue(d.submitted);
        assertEq(d.totalUsd, 2 * USD + USD / 2);
        assertEq(d.allocationRoot, keccak256("root"));
        (uint256[] memory ids, uint128[] memory amounts) = ledger.getDailyRevenue(0);
        assertEq(ids.length, 2);
        assertEq(ids[0], agentA);
        assertEq(amounts[0], 2 * USD);
        assertEq(ledger.getAgentDailyRevenue(0, agentB), USD / 2);
        assertEq(ledger.totalRecognizedUsd(), 2 * USD + USD / 2);
        assertEq(ledger.submittedDayCount(), 1);
    }

    function test_SubmitEmptyDay() public {
        vm.warp(GENESIS + DAY);
        vm.prank(backend);
        ledger.submitDailyRevenue(0, new uint256[](0), new uint128[](0), bytes32(0));
        assertTrue(ledger.getDay(0).submitted);
    }

    function test_RevertWhen_DayNotClosed() public {
        _payTao("pay-1", 30 * USD);
        vm.expectRevert(abi.encodeWithSelector(CounselixLedger.DayNotClosed.selector, uint64(0)));
        _submit(0, agentA, USD, agentB, USD);
    }

    function test_RevertWhen_DaySubmittedTwice() public {
        _payTao("pay-1", 30 * USD);
        vm.warp(GENESIS + DAY);
        _submit(0, agentA, USD, agentB, USD);
        vm.expectRevert(abi.encodeWithSelector(CounselixLedger.DayAlreadySubmitted.selector, uint64(0)));
        _submit(0, agentA, USD, agentB, USD);
    }

    function test_RevertWhen_RevenueExceedsPayments() public {
        _payTao("pay-1", 3 * USD);
        vm.warp(GENESIS + DAY);
        vm.expectRevert(abi.encodeWithSelector(CounselixLedger.RevenueExceedsPayments.selector, 4 * USD, 3 * USD));
        _submit(0, agentA, 2 * USD, agentB, 2 * USD);
    }

    function test_RevertWhen_BadRevenueRows() public {
        _payTao("pay-1", 30 * USD);
        vm.warp(GENESIS + DAY);
        vm.expectRevert(abi.encodeWithSelector(CounselixLedger.DuplicateAgent.selector, agentA));
        _submit(0, agentA, USD, agentA, USD);
        vm.expectRevert(abi.encodeWithSelector(CounselixLedger.UnknownAgent.selector, uint256(99)));
        _submit(0, agentA, USD, 99, USD);
        vm.expectRevert(CounselixLedger.ZeroAmount.selector);
        _submit(0, agentA, USD, agentB, 0);

        uint256[] memory ids = new uint256[](1);
        vm.prank(backend);
        vm.expectRevert(CounselixLedger.LengthMismatch.selector);
        ledger.submitDailyRevenue(0, ids, new uint128[](2), bytes32(0));
    }

    function testFuzz_RecognizedNeverExceedsPaid(uint128 paid, uint128 a, uint128 b) public {
        paid = uint128(bound(paid, 1, 1e15));
        a = uint128(bound(a, 1, 1e15));
        b = uint128(bound(b, 1, 1e15));
        _payTao("pay-1", paid);
        vm.warp(GENESIS + DAY);
        uint256[] memory ids = new uint256[](2);
        uint128[] memory amounts = new uint128[](2);
        (ids[0], ids[1], amounts[0], amounts[1]) = (agentA, agentB, a, b);
        vm.prank(backend);
        if (uint256(a) + b > paid) vm.expectRevert();
        ledger.submitDailyRevenue(0, ids, amounts, bytes32(0));
        assertLe(ledger.totalRecognizedUsd(), ledger.totalPaidUsd());
    }

    // ----------------------------------------------------------- service status

    function test_ServiceDownUntilFirstHeartbeat() public {
        vm.warp(GENESIS + 1000);
        assertTrue(ledger.isServiceDown());
        vm.prank(backend);
        ledger.heartbeat();
        assertFalse(ledger.isServiceDown());
    }

    function test_ServiceDownAfterHeartbeatTimeout() public {
        vm.prank(backend);
        ledger.heartbeat();
        vm.warp(GENESIS + 180);
        assertFalse(ledger.isServiceDown());
        vm.warp(GENESIS + 181);
        assertTrue(ledger.isServiceDown());
    }

    function test_NoAgentsAvailableFlag() public {
        vm.startPrank(backend);
        ledger.setNoAgentsAvailable(true);
        assertTrue(ledger.isServiceDown());
        assertEq(ledger.noAgentsSince(), GENESIS);
        vm.warp(GENESIS + 60);
        ledger.setNoAgentsAvailable(false);
        vm.stopPrank();
        assertFalse(ledger.isServiceDown());
        assertEq(ledger.noAgentsSince(), 0);
        assertEq(ledger.lastHeartbeat(), GENESIS + 60);
    }

    function test_SetHeartbeatTimeout() public {
        vm.prank(admin);
        ledger.setHeartbeatTimeout(600);
        assertEq(ledger.heartbeatTimeout(), 600);
        vm.prank(admin);
        vm.expectRevert(CounselixLedger.InvalidTimeout.selector);
        ledger.setHeartbeatTimeout(0);
    }
}
