// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {DarkHorse} from "../contracts/DarkHorse.sol";

/// Deploy to Base Sepolia:
///   forge script script/Deploy.s.sol --rpc-url base_sepolia --broadcast \
///     --private-key $PRIVATE_KEY_BASE_SEPOLIA
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        DarkHorse dh = new DarkHorse();
        console.log("DarkHorse deployed at:", address(dh));
        vm.stopBroadcast();
    }
}
