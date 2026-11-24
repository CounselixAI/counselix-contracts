// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Source of the TAO market price used to value TAO subscription payments.
interface ITaoUsdOracle {
    /// @return Micro-USD (6 decimals) per 1 TAO.
    function taoUsdPrice() external view returns (uint256);
}
