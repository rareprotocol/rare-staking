// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../src/RareStakingV1.sol";

/// @dev This contract is only used for testing upgrades
contract RareStakingUpdateTest is RareStakingV1 {
    /// @notice Returns the total amount staked by an account plus any pending claims
    /// @param account The address to check
    /// @return total The total amount staked plus pending claims
    function getTotalAccountValue(
        address account
    ) external view returns (uint256) {
        return
            stakedAmount[account] +
            (lastClaimedRound[account] < currentRound ? 100 ether : 0);
    }
}
