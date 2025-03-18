// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

interface IRegulationStats {
    function addPegTokenEpochInfo(address _pegToken, uint256 epochNumber, uint256 twap, uint256 expanded, uint256 rebasedDown, uint256 boardroomFunding, uint256 psrFunding, uint256 devFunding) external;
}
