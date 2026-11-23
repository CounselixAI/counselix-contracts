// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {CounselixRegistry} from "../src/CounselixRegistry.sol";
import {CounselixLedger} from "../src/CounselixLedger.sol";

/// @notice Deploys CounselixRegistry and CounselixLedger.
/// Env vars:
///   ADMIN_ADDRESS     - holds DEFAULT_ADMIN_ROLE (use a multisig in production)
///   BACKEND_ADDRESS   - platform backend signer; gets OPERATOR_ROLE and RECORDER_ROLE
///   EPOCH_LENGTH      - epoch length in seconds (default 1 day)
///   GENESIS_TIMESTAMP - start of epoch 0 (default: deployment block time)
contract Deploy is Script {
    function run() external returns (CounselixRegistry registry, CounselixLedger ledger) {
        address admin = vm.envAddress("ADMIN_ADDRESS");
        address backend = vm.envAddress("BACKEND_ADDRESS");
        uint64 epochLength = uint64(vm.envOr("EPOCH_LENGTH", uint256(1 days)));
        uint64 genesis = uint64(vm.envOr("GENESIS_TIMESTAMP", uint256(0)));

        vm.startBroadcast();
        registry = new CounselixRegistry(admin, backend);
        ledger = new CounselixLedger(admin, backend, registry, genesis, epochLength);
        vm.stopBroadcast();

        console.log("CounselixRegistry:", address(registry));
        console.log("CounselixLedger:  ", address(ledger));
    }
}
