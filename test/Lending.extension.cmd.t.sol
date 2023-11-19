// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@email-wallet/test/helpers/EmailWalletCoreTestHelper.sol";
import "../src/LendingExtension.sol";
import "../src/DAI.sol";

// Testing extension functionality
contract LendingExtensionCommandTest is EmailWalletCoreTestHelper {
    LendingExtension lendingExtension;
    string[][] public lendingExtTemplates = new string[][](3);

    fallback() external {
        // For one test below to call this contract with empty calldata
    }

    function setUp() public override {
        super.setUp();
        _registerRelayer();
        _registerAndInitializeAccount();

        lendingExtension = new LendingExtension(address(core));
        // Lending Borrow 10 of DAI to 0x6813Eb9362372EEF6200f3b1dbC3f819671cBA69
        lendingExtTemplates[0] = ["Lending", "Borrow", "{uint}", "of", "{string}", "to", "{recipient}"];
        lendingExtTemplates[1] = ["Lending", "Redeem", "{uint}", "of", "{string}", "to", "{recipient}"];
        lendingExtTemplates[2] = ["Lending", "Approve", "{recipient}", "for", "{uint}", "of", "{string}"];
        // Publish and install extension
        extensionHandler.publishExtension("Lending", address(lendingExtension), lendingExtTemplates, 0.1 ether);

        // deploy token
        DAI daiToken = new DAI("DAI Token", "DAI");
        DAI usdcToken = new DAI("USDC Token", "USDC");
        DAI weth = new DAI("Wrapped ETH Token", "WETH");
        // deploy lending protocol
        daiStable daiStableContract = new daiStable(DAI(daiToken));
        // addReserveVault
        daiStableContract.addReserveVault(usdcToken);
        daiStableContract.addReserveVault(weth);

        // set address
        lendingExtension.setTokenAddress("DAI", address(daiStableContract));

        // init email operation
        EmailOp memory emailOp = _getBaseEmailOp();
        emailOp.command = Commands.INSTALL_EXTENSION;
        emailOp.extensionName = "Lending";
        emailOp.maskedSubject = "Install extension Lending";
        emailOp.emailNullifier = bytes32(uint256(93845));

        vm.startPrank(relayer);
        core.handleEmailOp(emailOp);
        vm.stopPrank();
    }

    function test_Borrow() public {
        address recipient = vm.addr(3);

        EmailOp memory emailOp = _getBaseEmailOp();
        emailOp.command = "Lending";
        emailOp.maskedSubject = string.concat(
            "Lending Borrow 10 of DAI to ",
            SubjectUtils.addressToChecksumHexString(recipient)
        );
        emailOp.extensionParams.subjectTemplateIndex = 0;
        emailOp.hasEmailRecipient = false;
        emailOp.recipientETHAddr = recipient;
        emailOp.extensionParams.subjectParams = new bytes[](2);
        emailOp.extensionParams.subjectParams[0] = abi.encode(uint256(10));
        emailOp.extensionParams.subjectParams[1] = abi.encode(string("DAI"));

        vm.startPrank(relayer);
        core.handleEmailOp(emailOp);
        vm.stopPrank();
    }
    function test_Redeem() public {
        address recipient = vm.addr(3);

        EmailOp memory emailOpRedeem = _getBaseEmailOp();
        emailOpRedeem.command = "Lending";
        emailOpRedeem.maskedSubject = string.concat(
            "Lending Redeem 10 of DAI to ",
            SubjectUtils.addressToChecksumHexString(recipient)
        );
        emailOpRedeem.extensionParams.subjectTemplateIndex = 1;
        emailOpRedeem.hasEmailRecipient = false;
        emailOpRedeem.recipientETHAddr = recipient;
        emailOpRedeem.extensionParams.subjectParams = new bytes[](2);
        emailOpRedeem.extensionParams.subjectParams[0] = abi.encode(uint256(10));
        emailOpRedeem.extensionParams.subjectParams[1] = abi.encode(string("DAI"));

        vm.startPrank(relayer);
        core.handleEmailOp(emailOpRedeem);
        vm.stopPrank();
    }
}
