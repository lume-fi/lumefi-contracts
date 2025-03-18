// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../owner/Operator.sol";
import "../elastic/UFragments.sol";

/**
 * @title ElasticToken
 * @notice An elastic supply token that leverages the uFragments mechanism for rebasing.
 * @dev This token allows operator-controlled minting and owner-restricted recovery of unsupported ERC20 tokens.
 * It extends the UFragments contract for elastic supply functionality and Operator for role-based access.
 */
contract ElasticToken is UFragments, Operator {
    using SafeERC20 for IERC20;

    /**
     * @notice Constructor for ElasticToken.
     * @param _name The name of the token.
     * @param _symbol The symbol of the token.
     * @dev Initializes the token by calling the UFragments constructor.
     */
    constructor(string memory _name, string memory _symbol) UFragments(_name, _symbol) {
        // No additional initialization required.
    }

    /**
     * @notice Mints new tokens (in fragments) to a specified recipient.
     * @param recipient The address to receive the minted tokens.
     * @param amount The amount of tokens (in fragments) to mint.
     * @return success A boolean value indicating whether the recipient's balance increased after minting.
     * @dev This function can only be called by an account with the operator role.
     */
    function mint(address recipient, uint256 amount) public onlyOperator returns (bool success) {
        uint256 balanceBefore = balanceOf(recipient);
        _mint(recipient, amount);
        uint256 balanceAfter = balanceOf(recipient);
        return balanceAfter > balanceBefore;
    }

    /**
     * @notice Recovers ERC20 tokens that were accidentally sent to this contract.
     * @param token The ERC20 token contract to recover tokens from.
     * @param amount The amount of tokens to recover.
     * @param to The address that will receive the recovered tokens.
     * @dev This function can only be called by the owner. It uses SafeERC20 to safely transfer tokens
     * and ensures that tokens are not transferred to the zero address.
     */
    function governanceRecoverUnsupported(IERC20 token, uint256 amount, address to) external onlyOwner {
        require(to != address(0), "ElasticToken: Cannot transfer to zero address");
        token.safeTransfer(to, amount);
    }
}
