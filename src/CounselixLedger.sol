// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {CounselixRegistry} from "./CounselixRegistry.sol";

/// @title CounselixLedger
/// @notice On-chain record of subscription payments and of per-epoch revenue attribution to agents.
/// @dev Flow:
///        1. The backend (RECORDER_ROLE) records each subscription payment as it happens.
///        2. After an epoch ends, the backend submits how that epoch's recognized revenue is
///           attributed to agents (by usage share), in one or more chunks.
///        3. The backend finalizes the epoch with a Merkle root of the underlying usage records.
///           Finalized epochs are immutable.
///        4. Validators read finalized epochs and weight miners by attributed revenue.
///      All amounts are in micro-USD (6 decimals): 1 USD = 1_000_000.
///      User identifiers are salted hashes; no personal data goes on-chain.
contract CounselixLedger is AccessControl {
    bytes32 public constant RECORDER_ROLE = keccak256("RECORDER_ROLE");

    struct Payment {
        bytes32 userId;
        uint128 amount;
        uint64 paidAt;
        uint64 periodStart;
        uint64 periodEnd;
    }

    struct AgentEpochStats {
        uint128 revenue;
        uint64 consultations;
        uint32 uniquePayers;
    }

    struct AttributionRow {
        uint256 agentId;
        uint128 revenue;
        uint64 consultations;
        uint32 uniquePayers;
    }

    struct EpochSummary {
        uint128 totalRevenue;
        uint64 totalConsultations;
        uint32 agentCount;
        bool finalized;
        bytes32 usageRoot;
    }

    CounselixRegistry public immutable registry;
    /// @notice Unix timestamp at which epoch 0 starts.
    uint64 public immutable genesis;
    /// @notice Epoch length in seconds.
    uint64 public immutable epochLength;

    uint256 public paymentCount;
    uint256 public totalPaymentVolume;
    mapping(bytes32 => Payment) private _payments;

    /// @notice Highest finalized epoch + 1 (0 means none finalized yet).
    uint64 public finalizedEpochCount;
    mapping(uint64 => EpochSummary) private _epochs;
    mapping(uint64 => uint256[]) private _epochAgentIds;
    mapping(uint64 => mapping(uint256 => AgentEpochStats)) private _agentStats;

    event PaymentRecorded(
        bytes32 indexed paymentId,
        bytes32 indexed userId,
        uint128 amount,
        uint64 paidAt,
        uint64 periodStart,
        uint64 periodEnd
    );
    event AttributionSubmitted(
        uint64 indexed epoch, uint256 indexed agentId, uint128 revenue, uint64 consultations, uint32 uniquePayers
    );
    event EpochReset(uint64 indexed epoch);
    event EpochFinalized(uint64 indexed epoch, uint128 totalRevenue, uint64 totalConsultations, bytes32 usageRoot);

    error ZeroEpochLength();
    error ZeroId();
    error ZeroAmount();
    error InvalidPeriod();
    error DuplicatePayment(bytes32 paymentId);
    error UnknownPayment(bytes32 paymentId);
    error EpochNotEnded(uint64 epoch);
    error EpochAlreadyFinalized(uint64 epoch);
    error EpochNotFinalized(uint64 epoch);
    error EpochOutOfOrder(uint64 expected, uint64 got);
    error UnknownAgent(uint256 agentId);
    error DuplicateAttribution(uint64 epoch, uint256 agentId);

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

    // ------------------------------------------------------------------ payments

    function recordPayment(
        bytes32 paymentId,
        bytes32 userId,
        uint128 amount,
        uint64 paidAt,
        uint64 periodStart,
        uint64 periodEnd
    ) external onlyRole(RECORDER_ROLE) {
        if (paymentId == bytes32(0) || userId == bytes32(0)) revert ZeroId();
        if (amount == 0) revert ZeroAmount();
        if (periodEnd <= periodStart) revert InvalidPeriod();
        if (_payments[paymentId].amount != 0) revert DuplicatePayment(paymentId);

        _payments[paymentId] = Payment(userId, amount, paidAt, periodStart, periodEnd);
        paymentCount += 1;
        totalPaymentVolume += amount;
        emit PaymentRecorded(paymentId, userId, amount, paidAt, periodStart, periodEnd);
    }

    function getPayment(bytes32 paymentId) external view returns (Payment memory p) {
        p = _payments[paymentId];
        if (p.amount == 0) revert UnknownPayment(paymentId);
    }

    // --------------------------------------------------------------- attribution

    /// @notice Submit attribution rows for an ended, unfinalized epoch. May be called in chunks.
    ///         Rows with zero revenue and zero consultations are ignored.
    function submitAttribution(uint64 epoch, AttributionRow[] calldata rows) external onlyRole(RECORDER_ROLE) {
        _requireOpenEndedEpoch(epoch);
        for (uint256 i; i < rows.length; ++i) {
            _addRow(epoch, rows[i]);
        }
    }

    /// @notice Discard all attribution rows of an unfinalized epoch (to correct a bad submission).
    function resetEpoch(uint64 epoch) external onlyRole(RECORDER_ROLE) {
        if (_epochs[epoch].finalized) revert EpochAlreadyFinalized(epoch);
        uint256[] storage ids = _epochAgentIds[epoch];
        for (uint256 i; i < ids.length; ++i) {
            delete _agentStats[epoch][ids[i]];
        }
        delete _epochAgentIds[epoch];
        delete _epochs[epoch];
        emit EpochReset(epoch);
    }

    /// @notice Seal an epoch. Epochs must be finalized in order with no gaps (empty epochs are allowed).
    /// @param usageRoot Merkle root of the off-chain usage records backing this epoch's attribution.
    function finalizeEpoch(uint64 epoch, bytes32 usageRoot) external onlyRole(RECORDER_ROLE) {
        if (epoch != finalizedEpochCount) revert EpochOutOfOrder(finalizedEpochCount, epoch);
        _requireOpenEndedEpoch(epoch);
        EpochSummary storage summary = _epochs[epoch];
        summary.finalized = true;
        summary.usageRoot = usageRoot;
        finalizedEpochCount = epoch + 1;
        emit EpochFinalized(epoch, summary.totalRevenue, summary.totalConsultations, usageRoot);
    }

    // ---------------------------------------------------------------- validators

    function getEpochSummary(uint64 epoch) external view returns (EpochSummary memory) {
        return _epochs[epoch];
    }

    function getAgentEpochStats(uint64 epoch, uint256 agentId) external view returns (AgentEpochStats memory) {
        return _agentStats[epoch][agentId];
    }

    /// @notice Full attribution table of a finalized epoch, for validators.
    function getEpochAttribution(uint64 epoch)
        external
        view
        returns (
            uint256[] memory agentIds,
            uint128[] memory revenues,
            uint64[] memory consultations,
            uint32[] memory uniquePayers
        )
    {
        if (!_epochs[epoch].finalized) revert EpochNotFinalized(epoch);
        agentIds = _epochAgentIds[epoch];
        uint256 n = agentIds.length;
        revenues = new uint128[](n);
        consultations = new uint64[](n);
        uniquePayers = new uint32[](n);
        for (uint256 i; i < n; ++i) {
            AgentEpochStats storage s = _agentStats[epoch][agentIds[i]];
            revenues[i] = s.revenue;
            consultations[i] = s.consultations;
            uniquePayers[i] = s.uniquePayers;
        }
    }

    // ------------------------------------------------------------------ internal

    function _addRow(uint64 epoch, AttributionRow calldata row) private {
        if (!registry.agentExists(row.agentId)) revert UnknownAgent(row.agentId);
        AgentEpochStats storage s = _agentStats[epoch][row.agentId];
        if (s.revenue != 0 || s.consultations != 0) revert DuplicateAttribution(epoch, row.agentId);
        if (row.revenue == 0 && row.consultations == 0) return;

        s.revenue = row.revenue;
        s.consultations = row.consultations;
        s.uniquePayers = row.uniquePayers;
        _epochAgentIds[epoch].push(row.agentId);

        EpochSummary storage summary = _epochs[epoch];
        summary.totalRevenue += row.revenue;
        summary.totalConsultations += row.consultations;
        summary.agentCount += 1;
        emit AttributionSubmitted(epoch, row.agentId, row.revenue, row.consultations, row.uniquePayers);
    }

    function _requireOpenEndedEpoch(uint64 epoch) private view {
        if (_epochs[epoch].finalized) revert EpochAlreadyFinalized(epoch);
        (, uint64 end) = epochBounds(epoch);
        if (block.timestamp < end) revert EpochNotEnded(epoch);
    }
}
