// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {UniswapV3TaoUsdOracle, IUniswapV3PoolObserve} from "../src/oracles/UniswapV3TaoUsdOracle.sol";
import {MockERC20, MockPool} from "./mocks/Mocks.sol";

contract UniswapV3TaoUsdOracleTest is Test {
    MockERC20 wtao;
    MockERC20 usdc;

    function setUp() public {
        wtao = new MockERC20("WTAO", 18);
        usdc = new MockERC20("USDC", 6);
    }

    function _oracle(address token0, address token1, int56 tick) internal returns (UniswapV3TaoUsdOracle, MockPool) {
        MockPool pool = new MockPool(token0, token1, tick);
        return
            (new UniswapV3TaoUsdOracle(IUniswapV3PoolObserve(address(pool)), address(wtao), address(usdc), 1800), pool);
    }

    /// Reference values: floor(1.0001^tick * 2^128), computed with 100-digit decimal arithmetic.
    function test_RatioAtTick() public {
        (UniswapV3TaoUsdOracle o,) = _oracle(address(wtao), address(usdc), 0);
        assertEq(o.ratioAtTick(0), 1 << 128);
        assertApproxEqRel(o.ratioAtTick(1), 340316395157630557309720944892511388277, 1e3);
        assertApproxEqRel(o.ratioAtTick(-1), 340248342086729790484326174814286782777, 1e3);
        assertApproxEqRel(o.ratioAtTick(100), 343702089724658134425462205873642501801, 1e3);
        assertApproxEqRel(o.ratioAtTick(-100), 336896669234911992640369586824150439382, 1e3);
        assertApproxEqRel(o.ratioAtTick(224371), 1886518124298701293328696754580339296064283769347, 1e3);
        assertApproxEqRel(o.ratioAtTick(-224371), 61378731402520195968582970900, 1e3);
        assertApproxEqRel(o.ratioAtTick(500000), 1759859011403883232411658396185743491736454138057830842837113, 1e3);
        assertApproxEqRel(o.ratioAtTick(-500000), 65796230542892166, 1e3);
    }

    function test_RevertWhen_TickOutOfRange() public {
        (UniswapV3TaoUsdOracle o,) = _oracle(address(wtao), address(usdc), 0);
        vm.expectRevert(abi.encodeWithSelector(UniswapV3TaoUsdOracle.TickOutOfRange.selector, int256(500_001)));
        o.ratioAtTick(500_001);
    }

    /// Average tick -224371 on a WTAO(18)/USDC(6) pool is $180.375880 per TAO.
    function test_PriceWhenWtaoIsToken0() public {
        (UniswapV3TaoUsdOracle o,) = _oracle(address(wtao), address(usdc), -224371);
        assertApproxEqAbs(o.taoUsdPrice(), 180_375_880, 1);
    }

    function test_PriceWhenUsdcIsToken0() public {
        (UniswapV3TaoUsdOracle o,) = _oracle(address(usdc), address(wtao), 224371);
        assertApproxEqAbs(o.taoUsdPrice(), 180_375_880, 1);
    }

    function test_NegativeAverageRoundsDown() public {
        // A cumulative delta that is not a multiple of the window rounds toward negative infinity, like Uniswap.
        (UniswapV3TaoUsdOracle o, MockPool pool) = _oracle(address(wtao), address(usdc), -224371);
        pool.setAvgTick(-224372);
        assertLt(o.taoUsdPrice(), 180_375_880);
    }

    function test_RevertWhen_PoolTokensMismatch() public {
        MockERC20 other = new MockERC20("DAI", 18);
        MockPool pool = new MockPool(address(wtao), address(other), 0);
        vm.expectRevert(UniswapV3TaoUsdOracle.PoolTokenMismatch.selector);
        new UniswapV3TaoUsdOracle(IUniswapV3PoolObserve(address(pool)), address(wtao), address(usdc), 1800);
    }

    /// Reads the live WTAO/USDC pool on Bittensor EVM. Runs only with BITTENSOR_RPC_URL set.
    function test_Fork_LivePool() public {
        string memory rpc = vm.envOr("BITTENSOR_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        UniswapV3TaoUsdOracle o = new UniswapV3TaoUsdOracle(
            IUniswapV3PoolObserve(0x6647dcbeb030dc8E227D8B1A2Cb6A49F3C887E3c),
            0x9Dc08C6e2BF0F1eeD1E00670f80Df39145529F81,
            0xB833E8137FEDf80de7E908dc6fea43a029142F20,
            1800
        );
        uint256 price = o.taoUsdPrice();
        emit log_named_decimal_uint("TAO/USD (30 min average)", price, 6);
        assertGt(price, 1e6); // above $1
        assertLt(price, 100_000e6); // below $100,000
    }
}
