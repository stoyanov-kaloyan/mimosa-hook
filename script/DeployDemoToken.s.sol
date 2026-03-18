// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {MimosaDemoToken} from "../src/MimosaDemoToken.sol";

contract DeployDemoToken is Script {
    function run() external returns (MimosaDemoToken token) {
        string memory name = vm.envOr("TOKEN_NAME", string("Mimosa Demo USD"));
        string memory symbol = vm.envOr("TOKEN_SYMBOL", string("mUSD"));
        uint8 decimals = uint8(vm.envOr("TOKEN_DECIMALS", uint256(18)));
        uint256 mintAmount = vm.envOr("TOKEN_MINT_AMOUNT", uint256(1_000_000 ether));
        address mintTo = vm.envOr("TOKEN_MINT_TO", msg.sender);

        vm.startBroadcast();
        token = new MimosaDemoToken(name, symbol, decimals);
        token.mint(mintTo, mintAmount);
        vm.stopBroadcast();

        console2.log("Demo token:", address(token));
        console2.log("Minted to:", mintTo);
        console2.log("Mint amount:", mintAmount);
    }
}
