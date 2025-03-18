// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IEpoch} from "./IEpoch.sol";

interface ITreasury is IEpoch {
    function getPegTokenPrice(address _token) external view returns (uint256);

    function getPegTokenUpdatedPrice(address _token) external view returns (uint256);

    function getPegTokenLockedBalance(address _token) external view returns (uint256);

    function getPegTokenCirculatingSupply(address _token) external view returns (uint256);

    function getPegTokenExpansionRate(address _token) external view returns (uint256);

    function getPegTokenExpansionAmount(address _token) external view returns (uint256);

    function boardroom() external view returns (address);

    function boardroomSharedPercent() external view returns (uint256);

    function collateralReserves() external view returns (address);

    function collateralReservesSharedPercent() external view returns (uint256);

    function devFund() external view returns (address);

    function devFundSharedPercent() external view returns (uint256);

    function isTokenPrinter(address token, address account) external view returns (bool);

    function priceOne() external view returns (uint256);

    function priceCeiling() external view returns (uint256);

    function nova() external view returns (address);

    function novaOracle() external view returns (address);
}
