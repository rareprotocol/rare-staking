// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/RareStakingV1.sol";
import "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployRareStake is Script {
    function run() external {
        // Get deployment parameters from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address rareToken = vm.envAddress("RARE_TOKEN");
        bytes32 merkleRoot = bytes32(vm.envBytes32("INITIAL_MERKLE_ROOT"));
        address owner = vm.addr(deployerPrivateKey);

        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy implementation contract
        RareStakingV1 implementation = new RareStakingV1();

        // 2. Deploy proxy contract pointing to implementation (without init data)
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");

        // 3. Initialize the proxy
        RareStakingV1(address(proxy)).initialize(rareToken, merkleRoot, owner);

        // Log the addresses
        console.log("Implementation deployed at:", address(implementation));
        console.log("Proxy deployed at:", address(proxy));
        console.log(
            "Use the proxy address for all interactions:",
            address(proxy)
        );

        vm.stopBroadcast();
    }
}
