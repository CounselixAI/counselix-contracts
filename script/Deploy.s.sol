// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {CounselixRegistry} from "../src/CounselixRegistry.sol";
import {CounselixLedger} from "../src/CounselixLedger.sol";
import {CounselixTaoPayments} from "../src/CounselixTaoPayments.sol";
import {UniswapV3TaoUsdOracle, IUniswapV3PoolObserve} from "../src/oracles/UniswapV3TaoUsdOracle.sol";

/// @notice Deploys the Bittensor EVM contracts: Registry, Ledger, TAO price oracle and TAO payments.
/// Env vars:
///   ADMIN_ADDRESS          - final DEFAULT_ADMIN_ROLE holder (use a multisig in production)
///   BACKEND_ADDRESS        - platform backend key: Registry operator, Ledger recorder and relayer
///   TREASURY_ADDRESS       - receives TAO payments
///   MONTHLY_PRICE_USD      - monthly plan price in micro-USD (placeholder until prices are set)
///   ANNUAL_PRICE_USD       - annual plan price in micro-USD (placeholder until prices are set)
///   GENESIS_TIMESTAMP      - start of day 0; must be a UTC midnight (default: the last UTC midnight)
///   TAO_USDC_POOL, WTAO, POOL_USDC, TWAP_WINDOW - price source (defaults: the WTAO/USDC 0.3% pool)
contract Deploy is Script {
    address constant DEFAULT_POOL = 0x6647dcbeb030dc8E227D8B1A2Cb6A49F3C887E3c;
    address constant DEFAULT_WTAO = 0x9Dc08C6e2BF0F1eeD1E00670f80Df39145529F81;
    address constant DEFAULT_POOL_USDC = 0xB833E8137FEDf80de7E908dc6fea43a029142F20;

    struct Config {
        address admin;
        address backend;
        address treasury;
        uint128 monthly;
        uint128 annual;
        uint64 genesis;
        address pool;
        address wtao;
        address poolUsdc;
        uint32 window;
    }

    struct Deployment {
        CounselixRegistry registry;
        CounselixLedger ledger;
        UniswapV3TaoUsdOracle oracle;
        CounselixTaoPayments taoPayments;
    }

    function run() external returns (Deployment memory d) {
        Config memory c = _config();

        vm.startBroadcast();
        d = _deploy(c, msg.sender);
        vm.stopBroadcast();

        console.log("CounselixRegistry:    ", address(d.registry));
        console.log("CounselixLedger:      ", address(d.ledger));
        console.log("UniswapV3TaoUsdOracle:", address(d.oracle));
        console.log("CounselixTaoPayments: ", address(d.taoPayments));
        console.log("Ledger genesis:       ", c.genesis);
        console.log("TAO price (micro-USD):", d.oracle.taoUsdPrice());
    }

    function _config() internal view returns (Config memory c) {
        c.admin = vm.envAddress("ADMIN_ADDRESS");
        c.backend = vm.envAddress("BACKEND_ADDRESS");
        c.treasury = vm.envAddress("TREASURY_ADDRESS");
        c.monthly = uint128(vm.envUint("MONTHLY_PRICE_USD"));
        c.annual = uint128(vm.envUint("ANNUAL_PRICE_USD"));
        c.genesis = uint64(vm.envOr("GENESIS_TIMESTAMP", block.timestamp - (block.timestamp % 1 days)));
        c.pool = vm.envOr("TAO_USDC_POOL", DEFAULT_POOL);
        c.wtao = vm.envOr("WTAO", DEFAULT_WTAO);
        c.poolUsdc = vm.envOr("POOL_USDC", DEFAULT_POOL_USDC);
        c.window = uint32(vm.envOr("TWAP_WINDOW", uint256(1800)));
    }

    function _deploy(Config memory c, address deployer) internal returns (Deployment memory d) {
        d.registry = new CounselixRegistry(c.admin, c.backend);
        d.ledger = new CounselixLedger(deployer, d.registry, c.genesis);
        d.oracle = new UniswapV3TaoUsdOracle(IUniswapV3PoolObserve(c.pool), c.wtao, c.poolUsdc, c.window);
        d.taoPayments = new CounselixTaoPayments(c.admin, d.ledger, d.oracle, c.treasury, c.monthly, c.annual);

        d.ledger.grantRole(d.ledger.PAYMENTS_ROLE(), address(d.taoPayments));
        d.ledger.grantRole(d.ledger.RECORDER_ROLE(), c.backend);
        d.ledger.grantRole(d.ledger.RELAYER_ROLE(), c.backend);
        if (c.admin != deployer) {
            d.ledger.grantRole(d.ledger.DEFAULT_ADMIN_ROLE(), c.admin);
            d.ledger.renounceRole(d.ledger.DEFAULT_ADMIN_ROLE(), deployer);
        }
    }
}
