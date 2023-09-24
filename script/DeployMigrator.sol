// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import {Script} from "forge-std/Script.sol";
import {Migrator} from "../src/Migrator.sol";

contract DeployMigratorScript is Script {
    address ring = 0xB0ae108669CEB86E9E98e8fE9e40d98b867855fD;
    address ringV2 = 0x259c1C2ED264402b5ed2f02bc7dC25A15C680c18;
    address receiver = vm.envAddress("RECEIVER_ADDRESS");
    uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

    function run() public returns (Migrator migrator, address, address, address) {
        vm.startBroadcast(deployerKey);
        migrator = new Migrator(ring, ringV2, receiver);
        vm.stopBroadcast();

        return (migrator, ring, ringV2, receiver);
    }

    function testMock() public {}
}
