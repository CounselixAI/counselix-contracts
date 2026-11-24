// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ITaoUsdOracle} from "./ITaoUsdOracle.sol";

/// @notice The subset of the Uniswap V3 pool interface this oracle uses.
interface IUniswapV3PoolObserve {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

/// @title UniswapV3TaoUsdOracle
/// @notice TAO price from the time-weighted average tick of a WTAO/USDC Uniswap V3 pool on Bittensor EVM.
/// @dev One USDC is valued at one USD. The pool must keep enough observations to cover the window
///      (raise them once with `increaseObservationCardinalityNext` on the pool if needed).
contract UniswapV3TaoUsdOracle is ITaoUsdOracle {
    /// @dev 1.0001 in Q128.128 fixed point, rounded down.
    uint256 private constant ONE_BPS_Q128 = 340316395157630557309720944892511388277;
    uint256 private constant Q128 = 1 << 128;
    /// @dev Bound on the average tick: 1.0001^500000 is about 5e21, far beyond any realistic TAO price.
    int256 private constant MAX_ABS_TICK = 500_000;

    IUniswapV3PoolObserve public immutable pool;
    address public immutable wtao;
    address public immutable usdc;
    uint32 public immutable window;
    bool private immutable _wtaoIsToken0;
    /// @dev Converts a USDC-per-WTAO ratio in raw units into micro-USD per 1 TAO.
    uint256 private immutable _scale;

    error PoolTokenMismatch();
    error InvalidWindow();
    error TickOutOfRange(int256 tick);
    error ZeroPrice();

    constructor(IUniswapV3PoolObserve pool_, address wtao_, address usdc_, uint32 window_) {
        if (window_ == 0) revert InvalidWindow();
        address token0 = pool_.token0();
        address token1 = pool_.token1();
        if (!((token0 == wtao_ && token1 == usdc_) || (token0 == usdc_ && token1 == wtao_))) {
            revert PoolTokenMismatch();
        }
        pool = pool_;
        wtao = wtao_;
        usdc = usdc_;
        window = window_;
        _wtaoIsToken0 = token0 == wtao_;
        // micro-USD per TAO = usdcRawPerWtaoRaw * 10^wtaoDecimals * 10^6 / 10^usdcDecimals
        _scale = 10 ** (uint256(IERC20Metadata(wtao_).decimals()) + 6) / 10 ** uint256(IERC20Metadata(usdc_).decimals());
    }

    /// @inheritdoc ITaoUsdOracle
    function taoUsdPrice() external view returns (uint256 price) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        (int56[] memory tickCumulatives,) = pool.observe(secondsAgos);
        int256 delta = int256(tickCumulatives[1]) - int256(tickCumulatives[0]);
        int256 avgTick = delta / int256(uint256(window));
        if (delta < 0 && delta % int256(uint256(window)) != 0) avgTick--; // round toward negative infinity

        uint256 ratio = ratioAtTick(avgTick); // token1 raw per token0 raw, Q128
        price = _wtaoIsToken0 ? Math.mulDiv(ratio, _scale, Q128) : Math.mulDiv(_scale, Q128, ratio);
        if (price == 0) revert ZeroPrice();
    }

    /// @notice 1.0001^tick in Q128.128 fixed point.
    function ratioAtTick(int256 tick) public pure returns (uint256 ratio) {
        if (tick > MAX_ABS_TICK || tick < -MAX_ABS_TICK) revert TickOutOfRange(tick);
        uint256 remaining = uint256(tick < 0 ? -tick : tick);
        ratio = Q128;
        uint256 base = ONE_BPS_Q128;
        while (remaining != 0) {
            if (remaining & 1 != 0) ratio = Math.mulDiv(ratio, base, Q128);
            remaining >>= 1;
            if (remaining != 0) base = Math.mulDiv(base, base, Q128);
        }
        if (tick < 0) ratio = Math.mulDiv(Q128, Q128, ratio);
    }
}
