// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/RareStaking.sol";

contract DeployRareStake is Script {
    function run() external {
        // Get deployment parameters from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address rareToken = vm.envAddress("RARE_TOKEN");
        bytes32 merkleRoot = bytes32(vm.envBytes32("INITIAL_MERKLE_ROOT"));

        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // Deploy RareStake contract
        RareStaking rareStake = new RareStaking(rareToken, merkleRoot);

        vm.stopBroadcast();

        // Log the deployment
        console2.log("RareStake deployed to:", address(rareStake));
    }
}
