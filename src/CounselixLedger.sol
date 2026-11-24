// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {CounselixRegistry} from "./CounselixRegistry.sol";
import {Plan} from "./Plan.sol";

/// @title CounselixLedger
/// @notice Public record of subscription payments, the daily revenue credited to each agent, and the
///         platform's service status. Validators read it to reward miners.
/// @dev Payments
///        - TAO payments are recorded by `CounselixTaoPayments` in the same transaction that forwards the
///          TAO to the treasury, together with the TAO/USD price used.
///        - USDC payments are made on Base through `CounselixUsdcPayments`. The backend relays each one here
///          with its Base transaction hash and log index, so anyone can check it against Base.
///        - Every payment has a fixed USD value, set at payment time.
///      Daily revenue
///        - Days follow UTC midnight. After a day ends, the backend submits the USD revenue each agent earned
///          that day (subscription value follows the agent that actually served the user), together with the
///          Merkle root of the per-user allocations behind it.
///        - Submitted days are immutable, and total revenue recognized can never exceed total USD paid.
///      Service status
///        - The backend sends a heartbeat every minute and flags when no agent on the platform is available.
///          `isServiceDown()` is the single definition validators use to decide when to burn emissions.
///      Amounts are micro-USD (6 decimals) and TAO is in wei (18 decimals). User ids are salted hashes.
contract CounselixLedger is AccessControl {
    bytes32 public constant PAYMENTS_ROLE = keccak256("PAYMENTS_ROLE");
    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");
    bytes32 public constant RECORDER_ROLE = keccak256("RECORDER_ROLE");

    uint64 public constant DAY = 1 days;

    enum Source {
        Tao,
        BaseUsdc
    }

    struct Payment {
        bytes32 userId;
        uint256 agentId;
        Plan plan;
        Source source;
        address payer;
        uint64 paidAt;
        /// @dev USD value of the payment, in micro-USD.
        uint128 usdAmount;
        /// @dev Amount paid in the payment token: TAO in wei, or USDC in its 6-decimal units.
        uint128 tokenAmount;
        /// @dev Micro-USD per 1 TAO used to value a TAO payment; 0 for USDC.
        uint128 taoUsdPrice;
        /// @dev For Base USDC payments: the Base transaction hash and log index of the payment event.
        bytes32 sourceTxHash;
        uint32 sourceLogIndex;
    }

    struct DayRecord {
        bool submitted;
        uint64 submittedAt;
        uint128 totalUsd;
        bytes32 allocationRoot;
    }

    CounselixRegistry public immutable registry;
    /// @notice Start of day 0, at a UTC midnight.
    uint64 public immutable genesis;

    uint256 public paymentCount;
    uint256 public totalPaidUsd;
    uint256 public totalRecognizedUsd;
    mapping(bytes32 => Payment) private _payments;
    mapping(bytes32 => bool) private _relayedLogs;

    uint64 public submittedDayCount;
    mapping(uint64 => DayRecord) private _days;
    mapping(uint64 => uint256[]) private _dayAgentIds;
    mapping(uint64 => mapping(uint256 => uint128)) private _dayRevenue;

    uint64 public lastHeartbeat;
    bool public noAgentsAvailable;
    uint64 public noAgentsSince;
    /// @notice The service counts as down when no heartbeat arrived for longer than this many seconds.
    uint64 public heartbeatTimeout = 180;

    event PaymentRecorded(
        bytes32 indexed paymentId,
        bytes32 indexed userId,
        uint256 indexed agentId,
        Source source,
        Plan plan,
        address payer,
        uint128 usdAmount,
        uint128 tokenAmount,
        uint128 taoUsdPrice
    );
    event BaseUsdcPaymentRelayed(bytes32 indexed paymentId, bytes32 indexed sourceTxHash, uint32 sourceLogIndex);
    event DailyRevenueSubmitted(uint64 indexed day, uint128 totalUsd, uint256 agentCount, bytes32 allocationRoot);
    event AgentDailyRevenue(uint64 indexed day, uint256 indexed agentId, uint128 usdAmount);
    event Heartbeat(uint64 timestamp);
    event NoAgentsAvailableChanged(bool noAgentsAvailable, uint64 timestamp);
    event HeartbeatTimeoutChanged(uint64 heartbeatTimeout);

    error GenesisNotMidnight(uint64 genesis);
    error ZeroId();
    error ZeroAmount();
    error ZeroAddress();
    error DuplicatePayment(bytes32 paymentId);
    error UnknownPayment(bytes32 paymentId);
    error AgentNotActive(uint256 agentId);
    error UnknownAgent(uint256 agentId);
    error DuplicateRelay(bytes32 sourceTxHash, uint32 sourceLogIndex);
    error DayNotClosed(uint64 day);
    error DayAlreadySubmitted(uint64 day);
    error LengthMismatch();
    error DuplicateAgent(uint256 agentId);
    error RevenueExceedsPayments(uint256 recognized, uint256 paid);
    error InvalidTimeout();

    constructor(address admin, CounselixRegistry registry_, uint64 genesis_) {
        if (genesis_ % DAY != 0) revert GenesisNotMidnight(genesis_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        registry = registry_;
        genesis = genesis_;
    }

    // ---------------------------------------------------------------------- days

    function currentDay() public view returns (uint64) {
        if (block.timestamp < genesis) return 0;
        return uint64((block.timestamp - genesis) / DAY);
    }

    function dayBounds(uint64 day) public view returns (uint64 start, uint64 end) {
        start = genesis + day * DAY;
        end = start + DAY;
    }

    function isDayClosed(uint64 day) public view returns (bool) {
        (, uint64 end) = dayBounds(day);
        return block.timestamp >= end;
    }

    // ------------------------------------------------------------------ payments

    /// @notice Record a TAO payment. Called by the TAO payments contract in the paying transaction.
    function recordTaoPayment(
        bytes32 paymentId,
        bytes32 userId,
        uint256 agentId,
        Plan plan,
        address payer,
        uint128 usdAmount,
        uint128 taoAmount,
        uint128 taoUsdPrice
    ) external onlyRole(PAYMENTS_ROLE) {
        if (!registry.isAgentActive(agentId)) revert AgentNotActive(agentId);
        if (taoAmount == 0 || taoUsdPrice == 0) revert ZeroAmount();
        _record(
            paymentId,
            Payment({
                userId: userId,
                agentId: agentId,
                plan: plan,
                source: Source.Tao,
                payer: payer,
                paidAt: uint64(block.timestamp),
                usdAmount: usdAmount,
                tokenAmount: taoAmount,
                taoUsdPrice: taoUsdPrice,
                sourceTxHash: bytes32(0),
                sourceLogIndex: 0
            })
        );
    }

    /// @notice Relay a USDC payment made on Base. Anyone can verify it against the Base transaction.
    function recordBaseUsdcPayment(
        bytes32 paymentId,
        bytes32 userId,
        uint256 agentId,
        Plan plan,
        address payer,
        uint128 usdcAmount,
        uint64 paidAt,
        bytes32 sourceTxHash,
        uint32 sourceLogIndex
    ) external onlyRole(RELAYER_ROLE) {
        if (!registry.agentExists(agentId)) revert UnknownAgent(agentId);
        if (sourceTxHash == bytes32(0)) revert ZeroId();
        bytes32 logKey = keccak256(abi.encode(sourceTxHash, sourceLogIndex));
        if (_relayedLogs[logKey]) revert DuplicateRelay(sourceTxHash, sourceLogIndex);
        _relayedLogs[logKey] = true;
        _record(
            paymentId,
            Payment({
                userId: userId,
                agentId: agentId,
                plan: plan,
                source: Source.BaseUsdc,
                payer: payer,
                paidAt: paidAt,
                usdAmount: usdcAmount,
                tokenAmount: usdcAmount,
                taoUsdPrice: 0,
                sourceTxHash: sourceTxHash,
                sourceLogIndex: sourceLogIndex
            })
        );
        emit BaseUsdcPaymentRelayed(paymentId, sourceTxHash, sourceLogIndex);
    }

    function getPayment(bytes32 paymentId) external view returns (Payment memory p) {
        p = _payments[paymentId];
        if (p.usdAmount == 0) revert UnknownPayment(paymentId);
    }

    // ------------------------------------------------------------- daily revenue

    /// @notice Submit the USD revenue each agent earned on a closed day. Each day can be submitted once.
    /// @param allocationRoot Merkle root of the per-user allocations behind these totals.
    function submitDailyRevenue(
        uint64 day,
        uint256[] calldata agentIds,
        uint128[] calldata usdAmounts,
        bytes32 allocationRoot
    ) external onlyRole(RECORDER_ROLE) {
        if (!isDayClosed(day)) revert DayNotClosed(day);
        DayRecord storage record = _days[day];
        if (record.submitted) revert DayAlreadySubmitted(day);
        if (agentIds.length != usdAmounts.length) revert LengthMismatch();

        uint256 total;
        for (uint256 i; i < agentIds.length; ++i) {
            uint256 agentId = agentIds[i];
            uint128 amount = usdAmounts[i];
            if (!registry.agentExists(agentId)) revert UnknownAgent(agentId);
            if (amount == 0) revert ZeroAmount();
            if (_dayRevenue[day][agentId] != 0) revert DuplicateAgent(agentId);
            _dayRevenue[day][agentId] = amount;
            _dayAgentIds[day].push(agentId);
            total += amount;
            emit AgentDailyRevenue(day, agentId, amount);
        }

        uint256 recognized = totalRecognizedUsd + total;
        if (recognized > totalPaidUsd) revert RevenueExceedsPayments(recognized, totalPaidUsd);
        totalRecognizedUsd = recognized;

        record.submitted = true;
        record.submittedAt = uint64(block.timestamp);
        record.totalUsd = SafeCast.toUint128(total);
        record.allocationRoot = allocationRoot;
        submittedDayCount += 1;
        emit DailyRevenueSubmitted(day, record.totalUsd, agentIds.length, allocationRoot);
    }

    function getDay(uint64 day) external view returns (DayRecord memory) {
        return _days[day];
    }

    /// @notice Revenue per agent for a submitted day.
    function getDailyRevenue(uint64 day)
        external
        view
        returns (uint256[] memory agentIds, uint128[] memory usdAmounts)
    {
        agentIds = _dayAgentIds[day];
        usdAmounts = new uint128[](agentIds.length);
        for (uint256 i; i < agentIds.length; ++i) {
            usdAmounts[i] = _dayRevenue[day][agentIds[i]];
        }
    }

    function getAgentDailyRevenue(uint64 day, uint256 agentId) external view returns (uint128) {
        return _dayRevenue[day][agentId];
    }

    // ------------------------------------------------------------ service status

    function heartbeat() external onlyRole(RECORDER_ROLE) {
        lastHeartbeat = uint64(block.timestamp);
        emit Heartbeat(lastHeartbeat);
    }

    /// @notice Flag whether no agent on the whole platform is available. Also counts as a heartbeat.
    function setNoAgentsAvailable(bool value) external onlyRole(RECORDER_ROLE) {
        lastHeartbeat = uint64(block.timestamp);
        if (value != noAgentsAvailable) {
            noAgentsAvailable = value;
            noAgentsSince = value ? uint64(block.timestamp) : 0;
            emit NoAgentsAvailableChanged(value, uint64(block.timestamp));
        }
        emit Heartbeat(lastHeartbeat);
    }

    /// @notice True while the platform cannot serve users: no agent is available, or the backend stopped
    ///         sending heartbeats. Validators burn miner emissions while this is true.
    function isServiceDown() external view returns (bool) {
        return noAgentsAvailable || block.timestamp > uint256(lastHeartbeat) + heartbeatTimeout;
    }

    function setHeartbeatTimeout(uint64 timeout) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (timeout == 0) revert InvalidTimeout();
        heartbeatTimeout = timeout;
        emit HeartbeatTimeoutChanged(timeout);
    }

    // ------------------------------------------------------------------ internal

    function _record(bytes32 paymentId, Payment memory p) private {
        if (paymentId == bytes32(0) || p.userId == bytes32(0)) revert ZeroId();
        if (p.usdAmount == 0) revert ZeroAmount();
        if (p.payer == address(0)) revert ZeroAddress();
        if (_payments[paymentId].usdAmount != 0) revert DuplicatePayment(paymentId);
        _payments[paymentId] = p;
        paymentCount += 1;
        totalPaidUsd += p.usdAmount;
        emit PaymentRecorded(
            paymentId, p.userId, p.agentId, p.source, p.plan, p.payer, p.usdAmount, p.tokenAmount, p.taoUsdPrice
        );
    }
}
