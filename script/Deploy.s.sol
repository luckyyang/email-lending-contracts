// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../src/LendingExtension.sol";
import {EmailWalletCore} from "../@email-wallet-local/src/EmailWalletCore.sol";
import {ExtensionHandler} from "../@email-wallet-local/src/handlers/ExtensionHandler.sol";

contract Deploy is Script {
    uint256 constant maxFeePerGas = 2 gwei;
    uint256 constant emailValidityDuration = 1 hours;
    uint256 constant unclaimedFundClaimGas = 450000;
    uint256 constant unclaimedStateClaimGas = 500000;
    uint256 constant unclaimsExpiryDuration = 30 days;

    string[][] lendingExtTemplates = new string[][](3);

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        if (deployerPrivateKey == 0) {
            console.log("PRIVATE_KEY env var not set");
            return;
        }
        address _core = vm.envAddress("EMAIL_WALLET_CORE");
        if (_core == address(0)) {
            console.log("EMAIL_WALLET_CORE env not set");
            return;
        }
        EmailWalletCore core = EmailWalletCore(payable(_core));
        ExtensionHandler extensionHandler = core.extensionHandler();
        vm.startBroadcast(deployerPrivateKey);
        LendingExtension lendingExtension = new LendingExtension(address(core));
        string memory extensionName = lendingExtension.getExtensionName();
        // string[][] memory executionTemplates = lendingExtension.templates();
        // uint256 maxExecutionGas = lendingExtension.maxExecutionGas();

        lendingExtTemplates[0] = ["Lending", "Borrow", "{uint}", "of", "{string}", "to", "{recipient}"];
        lendingExtTemplates[1] = ["Lending", "Redeem", "{uint}", "of", "{string}", "to", "{recipient}"];
        lendingExtTemplates[2] = ["Lending", "Approve", "{recipient}", "for", "{uint}", "of", "{string}"];

        // Publish and install extension
        extensionHandler.publishExtension("Lending", address(lendingExtension), lendingExtTemplates, 0.1 ether);

        // extensionHandler.publishExtension(
        //     extensionName,
        //     address(lendingExtension),
        //     executionTemplates,
        //     maxExecutionGas
        // );
        vm.stopBroadcast();
        console.log("Deployed at %s", address(lendingExtension));
    }
}
