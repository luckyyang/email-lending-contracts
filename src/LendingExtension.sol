// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import {Extension} from "@email-wallet/src/interfaces/Extension.sol";
import {EmailWalletCore} from "@email-wallet/src/EmailWalletCore.sol";
import "@email-wallet/src/interfaces/Types.sol";
import "./daiStable.sol";

// 1. can invoke dai transfer with approval(?)
// 2. can invoke dai transfer by parsing params from execute function
// 3. can invoke lending protocol
// 4. deploy and do integration test
contract LendingExtension is Extension, Ownable {
    EmailWalletCore public core;

    // Mapping from Token name to its address
    mapping(string => address) public addressOfTokenName;

    string[][] public templates = new string[][](3);

    modifier onlyCore() {
        require((msg.sender == address(core)) || (msg.sender == address(core.unclaimsHandler())), "invalid sender");
        _;
    }

    constructor(address coreAddr) {
        core = EmailWalletCore(payable(coreAddr));
        templates[0] = ["Lending", "Borrow", "{uint}", "of", "{string}", "to", "{recipient}"];
        templates[1] = ["Lending", "Redeem", "{uint}", "of", "{string}", "to", "{recipient}"];
        templates[2] = ["Lending", "Approve", "{recipient}", "for", "{uint}", "of", "{string}"];
    }

    /// @notice Set Token address for its name
    /// @param  tokenName Token name
    /// @param addr Address of the Token
    function setTokenAddress(string memory tokenName, address addr) public onlyOwner {
        require(addressOfTokenName[tokenName] == address(0), "Token already registered");
        require(addr != address(0), "invalid address");
        addressOfTokenName[tokenName] = addr;
    }

    function execute(
        uint8 templateIndex,
        bytes[] memory subjectParams,
        address wallet,
        bool hasEmailRecipient,
        address recipientETHAddr,
        bytes32
    ) external override onlyCore {
        // Parse subject tempaltes
        // This can be common for both templates as [0] is `tokenId` and [1] is `tokenName` (`recipient` is not included in subjectParams)
        uint256 amount = abi.decode(subjectParams[0], (uint256));
        string memory tokenName = abi.decode(subjectParams[1], (string));
        address daiAddr = addressOfTokenName[tokenName];
        require(daiAddr != address(0), "invalid token");

        // Borrow
        if (templateIndex == 0) {
            // If sending to email, approve for "this" (to transfer later) and register unclaimed state
            if (hasEmailRecipient) {
                bytes memory data = abi.encodeWithSignature("approve(address,uint256)", address(this), amount);
                core.executeAsExtension(daiAddr, data);

                bytes memory unclaimedState = abi.encode(daiAddr, amount);
                core.registerUnclaimedStateAsExtension(address(this), unclaimedState);
            }
            // If recipient is ETH addr, borrow directly to recipient
            else {
                require(recipientETHAddr != address(0), "should have recipientETHAddr");

                // daiStable(daiAddr).depositCollateral(0, amount, amount / 10);
                bytes memory data = abi.encodeWithSignature(
                    "depositCollateral(uint256,uint256,uint256)",
                    0,
                    amount,
                    amount / 10
                );
                core.executeAsExtension(daiAddr, data);
            }

            return;
        }

        // Redeem
        if (templateIndex == 1) {
            // If sending to email, approve for "this" (to transfer later) and register unclaimed state
            if (hasEmailRecipient) {
                bytes memory data = abi.encodeWithSignature("approve(address,uint256)", address(this), amount);
                core.executeAsExtension(daiAddr, data);

                bytes memory unclaimedState = abi.encode(daiAddr, amount);
                core.registerUnclaimedStateAsExtension(address(this), unclaimedState);
            }
            // If recipient is ETH addr, redeem directly to recipient
            else {
                require(recipientETHAddr != address(0), "should have recipientETHAddr");

                // daiStable(daiAddr).depositCollateral(0, amount, amount / 10);
                bytes memory data = abi.encodeWithSignature(
                    "redeemCollateral(uint256,uint256)",
                    0,
                    amount
                );
                core.executeAsExtension(daiAddr, data);
            }

            return;
        }

        // Approve
        if (templateIndex == 2) {
            require(recipientETHAddr != address(0), "should have ETH add for approve");

            bytes memory data = abi.encodeWithSignature("approve(address,uint256)", recipientETHAddr, amount);
            core.executeAsExtension(address(daiAddr), data);

            return;
        }

        revert("invalid templateIndex");
    }

    function getExtensionName()
        public view
        returns (string memory)
    {
        return "Lending-v1.0.0";
    }

}
