// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {CounselixLedger} from "./CounselixLedger.sol";
import {ITaoUsdOracle} from "./oracles/ITaoUsdOracle.sol";
import {Plan} from "./Plan.sol";

/// @title CounselixTaoPayments
/// @notice Subscriptions paid in TAO on Bittensor EVM. In one transaction, a payment sends the TAO for
///         the plan's USD price at the current market price to the treasury and records it in the Ledger.
/// @dev The contract never holds funds: the exact amount goes to the treasury and any excess sent by the
///      payer is returned in the same transaction.
contract CounselixTaoPayments is AccessControl, ReentrancyGuard {
    CounselixLedger public immutable ledger;
    ITaoUsdOracle public oracle;
    address public treasury;
    /// @notice Plan prices in micro-USD.
    mapping(Plan => uint128) public planPrice;

    event TaoPaymentReceived(
        bytes32 indexed paymentId,
        bytes32 indexed userId,
        uint256 indexed agentId,
        Plan plan,
        address payer,
        uint128 usdAmount,
        uint128 taoAmount,
        uint128 taoUsdPrice
    );
    event TreasuryChanged(address treasury);
    event OracleChanged(address oracle);
    event PlanPriceChanged(Plan plan, uint128 usdAmount);

    error ZeroAddress();
    error PlanNotPriced(Plan plan);
    error InsufficientPayment(uint256 required, uint256 sent);
    error TransferFailed();

    constructor(
        address admin,
        CounselixLedger ledger_,
        ITaoUsdOracle oracle_,
        address treasury_,
        uint128 monthlyPrice,
        uint128 annualPrice
    ) {
        if (treasury_ == address(0) || address(oracle_) == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        ledger = ledger_;
        oracle = oracle_;
        treasury = treasury_;
        planPrice[Plan.Monthly] = monthlyPrice;
        planPrice[Plan.Annual] = annualPrice;
    }

    /// @notice The TAO amount (wei) a plan costs right now, and the price used (micro-USD per TAO).
    ///         Send a little more to absorb price movement before inclusion; the excess is returned.
    function quote(Plan plan) public view returns (uint256 taoAmount, uint256 taoUsdPrice) {
        uint256 usdAmount = planPrice[plan];
        if (usdAmount == 0) revert PlanNotPriced(plan);
        taoUsdPrice = oracle.taoUsdPrice();
        taoAmount = Math.mulDiv(usdAmount, 1e18, taoUsdPrice, Math.Rounding.Ceil);
    }

    /// @notice Pay for a subscription in TAO.
    /// @param paymentId Unique id of the checkout, issued by the platform.
    /// @param userId Salted hash of the platform user id.
    /// @param agentId The agent the user subscribes to.
    function pay(bytes32 paymentId, bytes32 userId, uint256 agentId, Plan plan) external payable nonReentrant {
        (uint256 taoAmount, uint256 taoUsdPrice) = quote(plan);
        if (msg.value < taoAmount) revert InsufficientPayment(taoAmount, msg.value);
        uint128 usdAmount = planPrice[plan];
        uint128 tao = SafeCast.toUint128(taoAmount);
        uint128 price = SafeCast.toUint128(taoUsdPrice);

        ledger.recordTaoPayment(paymentId, userId, agentId, plan, msg.sender, usdAmount, tao, price);
        emit TaoPaymentReceived(paymentId, userId, agentId, plan, msg.sender, usdAmount, tao, price);

        _send(treasury, taoAmount);
        if (msg.value > taoAmount) _send(msg.sender, msg.value - taoAmount);
    }

    // --------------------------------------------------------------------- admin

    function setTreasury(address treasury_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasuryChanged(treasury_);
    }

    function setOracle(ITaoUsdOracle oracle_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(oracle_) == address(0)) revert ZeroAddress();
        oracle = oracle_;
        emit OracleChanged(address(oracle_));
    }

    function setPlanPrice(Plan plan, uint128 usdAmount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        planPrice[plan] = usdAmount;
        emit PlanPriceChanged(plan, usdAmount);
    }

    function _send(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
