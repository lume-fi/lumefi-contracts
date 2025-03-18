// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

interface IBasisAsset {
    function mint(address recipient, uint256 amount) external returns (bool);

    function burn(uint256 amount) external;

    function burnFrom(address from, uint256 amount) external;

    function transferOperator(address newOperator_) external;

    function transferOwnership(address newOwner_) external;

    function totalBurned() external view returns (uint256);
}
