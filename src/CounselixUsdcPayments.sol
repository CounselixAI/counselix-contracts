// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Plan} from "./Plan.sol";

/// @title CounselixUsdcPayments
/// @notice Subscriptions paid in native USDC on Base. A payment moves the plan price from the payer
///         straight to the treasury and emits an event. The platform relays each payment to
///         `CounselixLedger` on Bittensor EVM with this transaction's hash and log index, where validators
///         check it against this event.
/// @dev The payer must first approve this contract for the plan price. The contract never holds funds.
contract CounselixUsdcPayments is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    address public treasury;
    /// @notice Plan prices in USDC units (6 decimals, equal to micro-USD).
    mapping(Plan => uint128) public planPrice;
    mapping(bytes32 => bool) public isPaid;

    event UsdcPaymentReceived(
        bytes32 indexed paymentId,
        bytes32 indexed userId,
        uint256 indexed agentId,
        Plan plan,
        address payer,
        uint128 amount
    );
    event TreasuryChanged(address treasury);
    event PlanPriceChanged(Plan plan, uint128 amount);

    error ZeroAddress();
    error ZeroId();
    error PlanNotPriced(Plan plan);
    error DuplicatePayment(bytes32 paymentId);

    constructor(address admin, IERC20 usdc_, address treasury_, uint128 monthlyPrice, uint128 annualPrice) {
        if (address(usdc_) == address(0) || treasury_ == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        usdc = usdc_;
        treasury = treasury_;
        planPrice[Plan.Monthly] = monthlyPrice;
        planPrice[Plan.Annual] = annualPrice;
    }

    /// @notice Pay for a subscription in USDC.
    /// @param paymentId Unique id of the checkout, issued by the platform.
    /// @param userId Salted hash of the platform user id.
    /// @param agentId The agent the user subscribes to (an agent id of `CounselixRegistry`).
    function pay(bytes32 paymentId, bytes32 userId, uint256 agentId, Plan plan) external nonReentrant {
        if (paymentId == bytes32(0) || userId == bytes32(0)) revert ZeroId();
        uint128 amount = planPrice[plan];
        if (amount == 0) revert PlanNotPriced(plan);
        if (isPaid[paymentId]) revert DuplicatePayment(paymentId);
        isPaid[paymentId] = true;

        usdc.safeTransferFrom(msg.sender, treasury, amount);
        emit UsdcPaymentReceived(paymentId, userId, agentId, plan, msg.sender, amount);
    }

    // --------------------------------------------------------------------- admin

    function setTreasury(address treasury_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasuryChanged(treasury_);
    }

    function setPlanPrice(Plan plan, uint128 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        planPrice[plan] = amount;
        emit PlanPriceChanged(plan, amount);
    }
}
