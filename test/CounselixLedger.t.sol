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

    uint256 agentA;
    uint256 agentB;

    function setUp() public {
        vm.warp(GENESIS);
        registry = new CounselixRegistry(admin, backend);
        ledger = new CounselixLedger(admin, backend, registry, GENESIS, EPOCH);

        vm.startPrank(backend);
        uint32 edu = registry.addCategory("Education");
        agentA = registry.registerAgent(keccak256("miner-a"), edu, "");
        agentB = registry.registerAgent(keccak256("miner-b"), edu, "");
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ helpers

    function _rows(uint256 a, uint128 ra, uint64 ca, uint256 b, uint128 rb, uint64 cb)
        internal
        pure
        returns (CounselixLedger.AttributionRow[] memory rows)
    {
        rows = new CounselixLedger.AttributionRow[](2);
        rows[0] = CounselixLedger.AttributionRow(a, ra, ca, 1);
        rows[1] = CounselixLedger.AttributionRow(b, rb, cb, 1);
    }

    function _submit(uint64 epoch, uint128 ra, uint128 rb) internal {
        CounselixLedger.AttributionRow[] memory rows = _rows(agentA, ra, 10, agentB, rb, 5);
        vm.prank(backend);
        ledger.submitAttribution(epoch, rows);
    }

    // ------------------------------------------------------------------- epochs

    function test_EpochMath() public {
        assertEq(ledger.currentEpoch(), 0);
        vm.warp(GENESIS + EPOCH * 3 + 1);
        assertEq(ledger.currentEpoch(), 3);
        (uint64 start, uint64 end) = ledger.epochBounds(2);
        assertEq(start, GENESIS + 2 * EPOCH);
        assertEq(end, GENESIS + 3 * EPOCH);
    }

    function test_RevertWhen_ZeroEpochLength() public {
        vm.expectRevert(CounselixLedger.ZeroEpochLength.selector);
        new CounselixLedger(admin, backend, registry, GENESIS, 0);
    }

    // ----------------------------------------------------------------- payments

    function test_RecordPayment() public {
        vm.prank(backend);
        ledger.recordPayment("pay-1", "user-1", 20 * USD, GENESIS, GENESIS, GENESIS + 30 days);

        CounselixLedger.Payment memory p = ledger.getPayment("pay-1");
        assertEq(p.userId, bytes32("user-1"));
        assertEq(p.amount, 20 * USD);
        assertEq(ledger.paymentCount(), 1);
        assertEq(ledger.totalPaymentVolume(), 20 * USD);
    }

    function test_RevertWhen_DuplicatePayment() public {
        vm.startPrank(backend);
        ledger.recordPayment("pay-1", "user-1", USD, GENESIS, GENESIS, GENESIS + 1);
        vm.expectRevert(abi.encodeWithSelector(CounselixLedger.DuplicatePayment.selector, bytes32("pay-1")));
        ledger.recordPayment("pay-1", "user-1", USD, GENESIS, GENESIS, GENESIS + 1);
        vm.stopPrank();
    }

    function test_RevertWhen_InvalidPayment() public {
        vm.startPrank(backend);
        vm.expectRevert(CounselixLedger.ZeroAmount.selector);
        ledger.recordPayment("pay-1", "user-1", 0, GENESIS, GENESIS, GENESIS + 1);
        vm.expectRevert(CounselixLedger.InvalidPeriod.selector);
        ledger.recordPayment("pay-1", "user-1", USD, GENESIS, GENESIS, GENESIS);
        vm.expectRevert(CounselixLedger.ZeroId.selector);
        ledger.recordPayment(bytes32(0), "user-1", USD, GENESIS, GENESIS, GENESIS + 1);
        vm.stopPrank();
    }

    function test_RevertWhen_StrangerRecordsPayment() public {
        bytes32 role = ledger.RECORDER_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role)
        );
        vm.prank(stranger);
        ledger.recordPayment("pay-1", "user-1", USD, GENESIS, GENESIS, GENESIS + 1);
    }

    // -------------------------------------------------------------- attribution

    function test_SubmitAndFinalize() public {
        vm.warp(GENESIS + EPOCH);
        _submit(0, 3 * USD, 1 * USD);
        vm.prank(backend);
        ledger.finalizeEpoch(0, keccak256("root"));

        CounselixLedger.EpochSummary memory s = ledger.getEpochSummary(0);
        assertTrue(s.finalized);
        assertEq(s.totalRevenue, 4 * USD);
        assertEq(s.totalConsultations, 15);
        assertEq(s.agentCount, 2);
        assertEq(s.usageRoot, keccak256("root"));
        assertEq(ledger.finalizedEpochCount(), 1);

        (uint256[] memory ids, uint128[] memory rev, uint64[] memory cons,) = ledger.getEpochAttribution(0);
        assertEq(ids.length, 2);
        assertEq(ids[0], agentA);
        assertEq(rev[0], 3 * USD);
        assertEq(cons[1], 5);
    }

    function test_SubmitInChunks() public {
        vm.warp(GENESIS + EPOCH);
        CounselixLedger.AttributionRow[] memory rows = new CounselixLedger.AttributionRow[](1);

        vm.startPrank(backend);
        rows[0] = CounselixLedger.AttributionRow(agentA, 2 * USD, 4, 1);
        ledger.submitAttribution(0, rows);
        rows[0] = CounselixLedger.AttributionRow(agentB, 1 * USD, 2, 1);
        ledger.submitAttribution(0, rows);
        vm.stopPrank();

        assertEq(ledger.getEpochSummary(0).totalRevenue, 3 * USD);
        assertEq(ledger.getAgentEpochStats(0, agentB).consultations, 2);
    }

    function test_ZeroRowsAreSkipped() public {
        vm.warp(GENESIS + EPOCH);
        _submit(0, 3 * USD, 0);
        // agentB had 5 consultations but no revenue, so it is still recorded
        assertEq(ledger.getEpochSummary(0).agentCount, 2);

        vm.warp(GENESIS + 2 * EPOCH);
        CounselixLedger.AttributionRow[] memory rows = _rows(agentA, USD, 1, agentB, 0, 0);
        vm.prank(backend);
        ledger.submitAttribution(1, rows);
        assertEq(ledger.getEpochSummary(1).agentCount, 1);
    }

    function test_RevertWhen_EpochNotEnded() public {
        vm.warp(GENESIS + EPOCH - 1);
        CounselixLedger.AttributionRow[] memory rows = _rows(agentA, USD, 1, agentB, USD, 1);
        vm.prank(backend);
        vm.expectRevert(abi.encodeWithSelector(CounselixLedger.EpochNotEnded.selector, uint64(0)));
        ledger.submitAttribution(0, rows);
    }

    function test_RevertWhen_DuplicateAttribution() public {
        vm.warp(GENESIS + EPOCH);
        _submit(0, USD, USD);
        CounselixLedger.AttributionRow[] memory rows = _rows(agentA, USD, 1, agentB, USD, 1);
        vm.prank(backend);
        vm.expectRevert(abi.encodeWithSelector(CounselixLedger.DuplicateAttribution.selector, uint64(0), agentA));
        ledger.submitAttribution(0, rows);
    }

    function test_RevertWhen_UnknownAgent() public {
        vm.warp(GENESIS + EPOCH);
        CounselixLedger.AttributionRow[] memory rows = _rows(agentA, USD, 1, 99, USD, 1);
        vm.prank(backend);
        vm.expectRevert(abi.encodeWithSelector(CounselixLedger.UnknownAgent.selector, uint256(99)));
        ledger.submitAttribution(0, rows);
    }

    function test_ResetEpoch() public {
        vm.warp(GENESIS + EPOCH);
        _submit(0, 3 * USD, 1 * USD);
        vm.prank(backend);
        ledger.resetEpoch(0);

        assertEq(ledger.getEpochSummary(0).totalRevenue, 0);
        assertEq(ledger.getAgentEpochStats(0, agentA).revenue, 0);

        _submit(0, 5 * USD, 1 * USD); // resubmission allowed after reset
        assertEq(ledger.getEpochSummary(0).totalRevenue, 6 * USD);
    }

    function test_RevertWhen_ModifyFinalizedEpoch() public {
        vm.warp(GENESIS + EPOCH);
        _submit(0, USD, USD);
        vm.startPrank(backend);
        ledger.finalizeEpoch(0, bytes32(0));

        vm.expectRevert(abi.encodeWithSelector(CounselixLedger.EpochAlreadyFinalized.selector, uint64(0)));
        ledger.resetEpoch(0);
        vm.expectRevert(abi.encodeWithSelector(CounselixLedger.EpochAlreadyFinalized.selector, uint64(0)));
        ledger.finalizeEpoch(0, bytes32(0));
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(CounselixLedger.EpochAlreadyFinalized.selector, uint64(0)));
        _submit(0, USD, USD);
    }

    function test_RevertWhen_FinalizeOutOfOrder() public {
        vm.warp(GENESIS + 3 * EPOCH);
        vm.prank(backend);
        vm.expectRevert(abi.encodeWithSelector(CounselixLedger.EpochOutOfOrder.selector, uint64(0), uint64(1)));
        ledger.finalizeEpoch(1, bytes32(0));
    }

    function test_FinalizeEmptyEpoch() public {
        vm.warp(GENESIS + EPOCH);
        vm.prank(backend);
        ledger.finalizeEpoch(0, bytes32(0));
        (uint256[] memory ids,,,) = ledger.getEpochAttribution(0);
        assertEq(ids.length, 0);
    }

    function test_RevertWhen_ReadUnfinalizedAttribution() public {
        vm.expectRevert(abi.encodeWithSelector(CounselixLedger.EpochNotFinalized.selector, uint64(0)));
        ledger.getEpochAttribution(0);
    }
}
