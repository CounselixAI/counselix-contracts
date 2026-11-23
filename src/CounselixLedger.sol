// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {CounselixRegistry} from "./CounselixRegistry.sol";

/// @title CounselixLedger
/// @notice On-chain record of subscription payments, attributed with the Selected Agent model:
///         every user picks one Main AI Agent, and 100% of each subscription payment they make is
///         credited to that agent (and so to the miner whose hotkey operates it).
/// @dev - The agent is fixed per payment. If a user switches Main Agent, the new agent is credited from
///        the user's next payment.
///      - Payments and refunds are credited to the epoch containing `block.timestamp`, not to a
///        backend-supplied time. Writes can therefore only land in the current epoch, and every past
///        epoch is closed and immutable by construction; no finalization step is needed.
///      - Refunds are recorded in the epoch in which they happen, against the original payment's agent.
///        Validators should score net revenue (revenue - refunded) summed over their scoring window.
///      All amounts are in micro-USD (6 decimals): 1 USD = 1_000_000.
///      User identifiers are salted hashes; no personal data goes on-chain.
contract CounselixLedger is AccessControl {
    bytes32 public constant RECORDER_ROLE = keccak256("RECORDER_ROLE");

    struct Payment {
        bytes32 userId;
        uint256 agentId;
        uint128 amount;
        uint128 refunded;
        uint64 paidAt;
        uint64 periodStart;
        uint64 periodEnd;
        uint64 epoch;
    }

    struct AgentEpochStats {
        uint128 revenue;
        uint128 refunded;
        uint32 payments;
        uint32 uniquePayers;
    }

    struct EpochSummary {
        uint128 revenue;
        uint128 refunded;
        uint32 payments;
        uint32 agentCount;
    }

    CounselixRegistry public immutable registry;
    /// @notice Unix timestamp at which epoch 0 starts.
    uint64 public immutable genesis;
    /// @notice Epoch length in seconds.
    uint64 public immutable epochLength;

    uint256 public paymentCount;
    uint256 public totalPaymentVolume;
    uint256 public totalRefundVolume;
    mapping(bytes32 => Payment) private _payments;

    mapping(uint64 => EpochSummary) private _epochs;
    mapping(uint64 => uint256[]) private _epochAgentIds;
    mapping(uint64 => mapping(uint256 => AgentEpochStats)) private _agentStats;
    mapping(uint64 => mapping(uint256 => bool)) private _listed;
    mapping(uint64 => mapping(uint256 => mapping(bytes32 => bool))) private _hasPaid;

    event PaymentRecorded(
        bytes32 indexed paymentId,
        bytes32 indexed userId,
        uint256 indexed agentId,
        uint64 epoch,
        uint128 amount,
        uint64 paidAt,
        uint64 periodStart,
        uint64 periodEnd
    );
    event RefundRecorded(bytes32 indexed paymentId, uint256 indexed agentId, uint64 epoch, uint128 amount);

    error ZeroEpochLength();
    error NotStarted();
    error ZeroId();
    error ZeroAmount();
    error InvalidPeriod();
    error AgentNotActive(uint256 agentId);
    error DuplicatePayment(bytes32 paymentId);
    error UnknownPayment(bytes32 paymentId);
    error RefundExceedsPayment(bytes32 paymentId, uint128 refundable);
    error EpochNotClosed(uint64 epoch);

    constructor(address admin, address recorder, CounselixRegistry registry_, uint64 genesis_, uint64 epochLength_) {
        if (epochLength_ == 0) revert ZeroEpochLength();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(RECORDER_ROLE, recorder);
        registry = registry_;
        genesis = genesis_ == 0 ? uint64(block.timestamp) : genesis_;
        epochLength = epochLength_;
    }

    // -------------------------------------------------------------------- epochs

    function currentEpoch() public view returns (uint64) {
        if (block.timestamp < genesis) return 0;
        return uint64((block.timestamp - genesis) / epochLength);
    }

    function epochBounds(uint64 epoch) public view returns (uint64 start, uint64 end) {
        start = genesis + epoch * epochLength;
        end = start + epochLength;
    }

    /// @notice True once an epoch has ended; its data can no longer change.
    function isEpochClosed(uint64 epoch) public view returns (bool) {
        (, uint64 end) = epochBounds(epoch);
        return block.timestamp >= end;
    }

    // ------------------------------------------------------------------ payments

    /// @notice Record a subscription payment, crediting 100% of it to the user's Main AI Agent.
    /// @param agentId The agent the user had selected as Main AI Agent when paying.
    function recordPayment(
        bytes32 paymentId,
        bytes32 userId,
        uint256 agentId,
        uint128 amount,
        uint64 paidAt,
        uint64 periodStart,
        uint64 periodEnd
    ) external onlyRole(RECORDER_ROLE) {
        if (block.timestamp < genesis) revert NotStarted();
        if (paymentId == bytes32(0) || userId == bytes32(0)) revert ZeroId();
        if (amount == 0) revert ZeroAmount();
        if (periodEnd <= periodStart) revert InvalidPeriod();
        if (_payments[paymentId].amount != 0) revert DuplicatePayment(paymentId);
        if (!registry.isAgentActive(agentId)) revert AgentNotActive(agentId);

        uint64 epoch = currentEpoch();
        _payments[paymentId] = Payment({
            userId: userId,
            agentId: agentId,
            amount: amount,
            refunded: 0,
            paidAt: paidAt,
            periodStart: periodStart,
            periodEnd: periodEnd,
            epoch: epoch
        });
        paymentCount += 1;
        totalPaymentVolume += amount;

        AgentEpochStats storage s = _stats(epoch, agentId);
        s.revenue += amount;
        s.payments += 1;
        if (!_hasPaid[epoch][agentId][userId]) {
            _hasPaid[epoch][agentId][userId] = true;
            s.uniquePayers += 1;
        }
        EpochSummary storage summary = _epochs[epoch];
        summary.revenue += amount;
        summary.payments += 1;

        emit PaymentRecorded(paymentId, userId, agentId, epoch, amount, paidAt, periodStart, periodEnd);
    }

    /// @notice Record a (partial or full) refund of a payment. It is booked in the current epoch against
    ///         the agent the payment was credited to; the epoch of the original payment is not changed.
    function recordRefund(bytes32 paymentId, uint128 amount) external onlyRole(RECORDER_ROLE) {
        if (amount == 0) revert ZeroAmount();
        Payment storage p = _payments[paymentId];
        if (p.amount == 0) revert UnknownPayment(paymentId);
        uint128 refundable = p.amount - p.refunded;
        if (amount > refundable) revert RefundExceedsPayment(paymentId, refundable);

        p.refunded += amount;
        totalRefundVolume += amount;

        uint64 epoch = currentEpoch();
        _stats(epoch, p.agentId).refunded += amount;
        _epochs[epoch].refunded += amount;
        emit RefundRecorded(paymentId, p.agentId, epoch, amount);
    }

    function getPayment(bytes32 paymentId) external view returns (Payment memory p) {
        p = _payments[paymentId];
        if (p.amount == 0) revert UnknownPayment(paymentId);
    }

    // ---------------------------------------------------------------- validators

    function getEpochSummary(uint64 epoch) external view returns (EpochSummary memory) {
        return _epochs[epoch];
    }

    function getAgentEpochStats(uint64 epoch, uint256 agentId) external view returns (AgentEpochStats memory) {
        return _agentStats[epoch][agentId];
    }

    /// @notice Full attribution table of a closed epoch, for validators. Only agents with a payment or
    ///         refund in the epoch are listed.
    function getEpochAttribution(uint64 epoch)
        external
        view
        returns (
            uint256[] memory agentIds,
            uint128[] memory revenues,
            uint128[] memory refunds,
            uint32[] memory payments,
            uint32[] memory uniquePayers
        )
    {
        if (!isEpochClosed(epoch)) revert EpochNotClosed(epoch);
        agentIds = _epochAgentIds[epoch];
        uint256 n = agentIds.length;
        revenues = new uint128[](n);
        refunds = new uint128[](n);
        payments = new uint32[](n);
        uniquePayers = new uint32[](n);
        for (uint256 i; i < n; ++i) {
            AgentEpochStats storage s = _agentStats[epoch][agentIds[i]];
            revenues[i] = s.revenue;
            refunds[i] = s.refunded;
            payments[i] = s.payments;
            uniquePayers[i] = s.uniquePayers;
        }
    }

    // ------------------------------------------------------------------ internal

    function _stats(uint64 epoch, uint256 agentId) private returns (AgentEpochStats storage) {
        if (!_listed[epoch][agentId]) {
            _listed[epoch][agentId] = true;
            _epochAgentIds[epoch].push(agentId);
            _epochs[epoch].agentCount += 1;
        }
        return _agentStats[epoch][agentId];
    }
}
