// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/RareStakingV1.sol";
import "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/interfaces/IRareStaking.sol";

contract DeployRareStake is Script {
    function run() external {
        // Get deployment parameters from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        // address rareToken = vm.envAddress("RARE_TOKEN");
        // address rewardsWallet = vm.envAddress("REWARDS_WALLET");
        // bytes32 merkleRoot = bytes32(vm.envBytes32("INITIAL_MERKLE_ROOT"));
        address owner = vm.addr(deployerPrivateKey);

        // // Validate inputs
        // if (rareToken == address(0)) revert IRareStaking.ZeroTokenAddress();
        // if (rewardsWallet == address(0)) revert IRareStaking.ZeroRewardsWalletAddress();
        // if (merkleRoot == bytes32(0)) revert IRareStaking.EmptyMerkleRoot();

        console.log("Deploying with parameters:");
        console.log("Owner:", owner);
        // console.log("RARE Token:", rareToken);
        // console.log("Rewards Wallet:", rewardsWallet);
        // console.log("Initial Merkle Root:", vm.toString(merkleRoot));

        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy implementation contract
        RareStakingV1 implementation = new RareStakingV1();
        console.log("Implementation deployed at:", address(implementation));

        // // 2. Deploy proxy contract pointing to implementation (without init data)
        // ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        // console.log("Proxy deployed at:", address(proxy));

        // // 3. Initialize the proxy with the implementation
        // RareStakingV1(address(proxy)).initialize(rareToken, rewardsWallet, merkleRoot, owner);
        // console.log("Proxy initialized successfully");

        // // 4. Verify the initialization
        // IRareStaking rareStaking = IRareStaking(address(proxy));
        // require(rareStaking.token() == rareToken, "Token address mismatch");
        // require(rareStaking.rewardsWallet() == rewardsWallet, "Rewards wallet mismatch");
        // require(
        //     rareStaking.currentClaimRoot() == merkleRoot,
        //     "Merkle root mismatch"
        // );
        // console.log("Deployment verified successfully");

        console.log("\nDeployment Summary:");
        console.log("===================");
        console.log("Implementation:", address(implementation));
        // console.log("Proxy:", address(proxy));
        // console.log("Owner:", owner);
        console.log("\nIMPORTANT: Use the proxy address for all interactions!");

        vm.stopBroadcast();
    }
}
