// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ITaoUsdOracle} from "../../src/oracles/ITaoUsdOracle.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory symbol, uint8 decimals_) ERC20(symbol, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockOracle is ITaoUsdOracle {
    uint256 public price;

    constructor(uint256 price_) {
        price = price_;
    }

    function setPrice(uint256 price_) external {
        price = price_;
    }

    function taoUsdPrice() external view returns (uint256) {
        return price;
    }
}

/// @dev Uniswap V3 pool stand-in that returns tick cumulatives for a constant average tick.
contract MockPool {
    address public token0;
    address public token1;
    int56 public avgTick;

    constructor(address token0_, address token1_, int56 avgTick_) {
        token0 = token0_;
        token1 = token1_;
        avgTick = avgTick_;
    }

    function setAvgTick(int56 tick) external {
        avgTick = tick;
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory liquidity)
    {
        tickCumulatives = new int56[](secondsAgos.length);
        liquidity = new uint160[](secondsAgos.length);
        int56 base = 1_000_000_000;
        for (uint256 i; i < secondsAgos.length; ++i) {
            tickCumulatives[i] = base - avgTick * int56(uint56(secondsAgos[i]));
        }
    }
}

/// @dev A payer that refuses refunds.
contract RejectingPayer {
    function pay(address target, bytes calldata data) external payable {
        (bool ok, bytes memory ret) = target.call{value: msg.value}(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}
