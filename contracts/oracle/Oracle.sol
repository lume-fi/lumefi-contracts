// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IUniswapV2Pair} from "../interfaces/IUniswapV2Pair.sol";
import {FixedPoint} from "../lib/FixedPoint.sol";
import {UniswapV2OracleLibrary} from "../lib/UniswapV2OracleLibrary.sol";
import {Epoch} from "../utils/Epoch.sol";

/**
 * @title Oracle
 * @notice A fixed-window Uniswap V2 oracle that computes the average price over a specified period (epoch).
 *         The oracle updates its average price once per epoch and guarantees an average computed over at least one full epoch.
 */
contract Oracle is Epoch {
    using FixedPoint for *;

    /* ========== STATE VARIABLES ========== */

    // Uniswap V2 pair details.
    address public token0;
    address public token1;
    IUniswapV2Pair public pair;

    // Oracle state variables.
    uint32 public _lastTimestamp; // Last timestamp when reserves were recorded.
    uint256 public price0CumulativeLast; // Last cumulative price for token0.
    uint256 public price1CumulativeLast; // Last cumulative price for token1.
    FixedPoint.uq112x112 public price0Average; // Average price for token0 over the epoch.
    FixedPoint.uq112x112 public price1Average; // Average price for token1 over the epoch.

    /* ========== CONSTRUCTOR ========== */

    /**
     * @notice Initializes the Oracle.
     * @param _pair The Uniswap V2 pair (e.g., TOKEN0/TOKEN1).
     * @param _period The epoch period (in seconds) over which the price is averaged.
     * @param _startTime The timestamp when the oracle should start operating.
     */
    constructor(IUniswapV2Pair _pair, uint256 _period, uint256 _startTime) Epoch(_period, _startTime, 0) {
        pair = _pair;
        token0 = pair.token0();
        token1 = pair.token1();

        // Initialize cumulative prices and last timestamp from the pair.
        price0CumulativeLast = pair.price0CumulativeLast();
        price1CumulativeLast = pair.price1CumulativeLast();
        (, , _lastTimestamp) = pair.getReserves();
        require(_lastTimestamp > 0, "Oracle: NO_RESERVES");
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    /**
     * @notice Updates the average prices for token0 and token1 over the current epoch.
     * @dev This function should be called once per epoch (enforced by the Epoch modifier).
     *      It uses current cumulative prices from Uniswap to calculate the average price.
     *      Note: Overflow in cumulative price difference is intentional.
     */
    function update() external checkEpoch {
        (uint256 currentPrice0Cumulative, uint256 currentPrice1Cumulative, uint32 currentTimestamp) = UniswapV2OracleLibrary.currentCumulativePrices(address(pair));
        uint32 timeElapsed = currentTimestamp - _lastTimestamp; // Overflow is desired.

        if (timeElapsed == 0) {
            // Avoid division by zero if no time has elapsed.
            return;
        }

        // Calculate the average prices over the elapsed time.
        price0Average = FixedPoint.uq112x112(uint224((currentPrice0Cumulative - price0CumulativeLast) / timeElapsed));
        price1Average = FixedPoint.uq112x112(uint224((currentPrice1Cumulative - price1CumulativeLast) / timeElapsed));

        // Update state for the next epoch.
        price0CumulativeLast = currentPrice0Cumulative;
        price1CumulativeLast = currentPrice1Cumulative;
        _lastTimestamp = currentTimestamp;

        emit Updated(currentPrice0Cumulative, currentPrice1Cumulative);
    }

    /**
     * @notice Returns the amount of output tokens for a given input amount based on the stored average price.
     * @dev Before the first successful update, this function returns 0.
     * @param _token The input token address (must be either token0 or token1).
     * @param _amountIn The input amount.
     * @return amountOut The output amount calculated from the average price.
     */
    function consult(address _token, uint256 _amountIn) external view returns (uint144 amountOut) {
        if (_token == token0) {
            amountOut = price0Average.mul(_amountIn).decode144();
        } else {
            require(_token == token1, "Oracle: INVALID_TOKEN");
            amountOut = price1Average.mul(_amountIn).decode144();
        }
    }

    /**
     * @notice Returns the time-weighted average price (TWAP) for a given input amount.
     * @dev This function calculates the TWAP using the current cumulative prices from Uniswap.
     * @param _token The input token address (must be either token0 or token1).
     * @param _amountIn The input amount.
     * @return amountOut The output amount calculated from the TWAP.
     */
    function twap(address _token, uint256 _amountIn) external view returns (uint144 amountOut) {
        (uint256 currentPrice0Cumulative, uint256 currentPrice1Cumulative, uint32 currentTimestamp) = UniswapV2OracleLibrary.currentCumulativePrices(address(pair));
        uint32 timeElapsed = currentTimestamp - _lastTimestamp; // Overflow is desired.

        if (_token == token0) {
            amountOut = FixedPoint.uq112x112(uint224((currentPrice0Cumulative - price0CumulativeLast) / timeElapsed)).mul(_amountIn).decode144();
        } else if (_token == token1) {
            amountOut = FixedPoint.uq112x112(uint224((currentPrice1Cumulative - price1CumulativeLast) / timeElapsed)).mul(_amountIn).decode144();
        }
    }

    /* ========== EVENTS ========== */

    /**
     * @notice Emitted when the oracle updates its cumulative prices.
     * @param price0CumulativeLast The new cumulative price for token0.
     * @param price1CumulativeLast The new cumulative price for token1.
     */
    event Updated(uint256 price0CumulativeLast, uint256 price1CumulativeLast);
}
