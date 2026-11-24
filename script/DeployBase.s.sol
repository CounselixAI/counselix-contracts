// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CounselixUsdcPayments} from "../src/CounselixUsdcPayments.sol";

/// @notice Deploys USDC payments on Base.
/// Env vars:
///   ADMIN_ADDRESS        - DEFAULT_ADMIN_ROLE holder (use a multisig in production)
///   BASE_TREASURY_ADDRESS - receives USDC payments on Base
///   MONTHLY_PRICE_USD    - monthly plan price in USDC units (6 decimals)
///   ANNUAL_PRICE_USD     - annual plan price in USDC units (6 decimals)
///   USDC_ADDRESS         - default: native USDC on Base
contract DeployBase is Script {
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function run() external returns (CounselixUsdcPayments usdcPayments) {
        address admin = vm.envAddress("ADMIN_ADDRESS");
        address treasury = vm.envAddress("BASE_TREASURY_ADDRESS");
        uint128 monthly = uint128(vm.envUint("MONTHLY_PRICE_USD"));
        uint128 annual = uint128(vm.envUint("ANNUAL_PRICE_USD"));
        address usdc = vm.envOr("USDC_ADDRESS", BASE_USDC);

        vm.startBroadcast();
        usdcPayments = new CounselixUsdcPayments(admin, IERC20(usdc), treasury, monthly, annual);
        vm.stopBroadcast();

        console.log("CounselixUsdcPayments:", address(usdcPayments));
    }
}
