// SPDX-License-Identifier: MIT LICENSE
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./DAI.sol";
import "./IC.sol";

contract daiStable is Ownable, ReentrancyGuard, AccessControl {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    error DAI__BreaksHealthFactor(uint256 healthFactorValue);

    uint256 public currentReserveId;

    struct UserData {
        uint256 totalUusdMinted;
        uint256 collateralValueInUsd;
        bool isLiquidated;
    }

    // Add a new struct to keep track of liquidation data for each user
    struct LiquidationData {
        uint256 debtToCover;
        uint256 collateralToRecover;
    }

    struct ReserveVault {
        IERC20 collateral;
        uint256 amount;
    }

    DAI private dai;
    IChronicle private pO;
    address public datafeed;
    uint256 public stableColatPrice = 1e18;
    uint256 public stableColatAmount;
    uint256 private constant COL_PRICE_TO_WEI = 1e10;
    uint256 private constant WEI_VALUE = 1e18;
    uint256 public unstableColatAmount;
    uint256 public unstableColPrice;
    uint256 private constant DEPOSIT_FEE = 1; // 0.001% fee
    uint256 private constant COLLATERALIZATION_RATIO = 150; // 150% collateralization ratio
    uint256 private constant LIQUIDATION_THRESHOLD = 67; // (150/100)*0.67=1   150% over-collateralized
    // 50 : This means you need to be 200% over-collateralized
    uint256 private constant LIQUIDATION_BONUS = 10; // This means you get assets at a 10% discount when liquidating
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant FEED_PRECISION = 1e8;

    address[] public investors1;
    uint public lastFetchedPrice;

    // Mapping to store liquidation data for each user and each collateral type (VID)
    mapping(address => mapping(uint256 => LiquidationData))
        public userLiquidationData;
    mapping(uint256 => ReserveVault) public _rsvVault;
    mapping(address => uint256) public userMintedDAI;
    mapping(address => mapping(uint256 => uint256)) public userCollateral;
    //mapping(address => uint256) public userBorrowed;
    mapping(address => bool) public isLiquidated;
    mapping(address => mapping(address => uint256))
        private s_collateralDeposited;

    // Mapping to store user minted DAI amounts for each VID (for VID 0)
    mapping(address => uint256) public userMintedDAIByCollateral0;

    // Mapping to store user minted DAI amounts for each VID (for VID 1)
    mapping(address => uint256) public userMintedDAIByCollateral1;

    // Mapping to store total collateral in USD by the contract for vid 0 and 1
    mapping(uint256 => uint256) public totalCollateralInUSD;

    mapping(address => uint256) public userHealthFactors;
    mapping(address => bool) public isBelowHealthFactorOne;

    // Event to signal users with unhealthy health factor
    event UnhealthyHealthFactor(address indexed user, uint256 healthFactor);
    event Withdraw(uint256 indexed vid, uint256 amount);
    event Deposit(uint256 indexed vid, uint256 amount);
    event CollateralRedeemed(
        address indexed redeemFrom,
        address indexed redeemTo,
        address token,
        uint256 amount
    ); // if redeemFrom != redeemedTo, then it was liquidated
    event Liquidate(
        address indexed user,
        uint256 indexed vid,
        uint256 amount,
        uint256 liquidationAmount
    );

    ///////////////////
    // Modifiers
    ///////////////////

    // Modifier to check if the user's health factor is good
    modifier hasGoodHealthFactor(address user) {
        require(
            _healthFactor(user) >= MIN_HEALTH_FACTOR,
            "UUSDEngine__HealthFactorNotOk"
        );
        _;
    }

    modifier moreThanZero(uint256 amount) {
        require(amount > 0, "Needs More Than Zero");
        _;
    }

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant GOVERN_ROLE = keccak256("GOVERN_ROLE");

    constructor(DAI _dai) {
        dai = _dai;
        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _setupRole(MANAGER_ROLE, _msgSender());
    }

    function checkReserveContract(IERC20 _collateral) internal view {
        for (uint256 i; i < currentReserveId; i++) {
            require(
                _rsvVault[i].collateral != _collateral,
                "Collateral Address Already Added"
            );
        }
    }

    function addReserveVault(IERC20 _collateral) external {
        require(hasRole(MANAGER_ROLE, _msgSender()), "Not allowed");
        checkReserveContract(_collateral);
        _rsvVault[currentReserveId].collateral = _collateral;
        currentReserveId++;
    }

    /*
   function chronicle(address oracle) external {
        uint x;
        x=IChronicle(oracle).read();
    }
    */

    function chronicle(address oracle) external view returns (uint) {
        require(Address.isContract(oracle), "Invalid Oracle contract address");

        IChronicle chronicleContract = IChronicle(oracle);

        uint price = chronicleContract.read();

        return price;
    }

    function logFetchedPrice(uint _price) external {
        require(hasRole(GOVERN_ROLE, _msgSender()), "Not allowed");
        emit PriceFetched(_price);
        lastFetchedPrice = _price;
    }

    event PriceFetched(uint price);

    // Function to update the total collateral in USD for a specific vid
    function _updateTotalCollateralInUSD(
        uint256 vid,
        uint256 amount,
        bool isDeposit
    ) internal {
        uint256 currentTotalCollateral = totalCollateralInUSD[vid];
        if (isDeposit) {
            totalCollateralInUSD[vid] = currentTotalCollateral.add(amount);
        } else {
            totalCollateralInUSD[vid] = currentTotalCollateral.sub(amount);
        }
    }

    function mintDaiIfHealthy(
        uint256 amountDaiToMint
    )
        public
        moreThanZero(amountDaiToMint)
        nonReentrant
        hasGoodHealthFactor(msg.sender)
    {
        uint256 totalCollateralValueInUSD = 0;
        for (uint256 vid = 0; vid < currentReserveId; vid++) {
            uint256 collateralAmount = userCollateral[msg.sender][vid];
            uint256 collateralPrice = getCollateralPrice(vid);

            // Calculate the collateral value in USD
            uint256 collateralValueInUSD = collateralAmount
                .mul(collateralPrice)
                .div(WEI_VALUE);
            totalCollateralValueInUSD = totalCollateralValueInUSD.add(
                collateralValueInUSD
            );
        }

        // Calculate the total borrowed value in USD (total minted DAI)
        uint256 totalBorrowedValueInUSD = userMintedDAI[msg.sender];

        // Check if the user has enough collateral to mint DAI
        require(
            totalCollateralValueInUSD >= totalBorrowedValueInUSD,
            "UUSDEngine__NotEnoughCollateral"
        );

        // Mint DAI tokens
        dai.mint(amountDaiToMint);

        // Transfer the minted DAI tokens to the user
        dai.transfer(msg.sender, amountDaiToMint);

        // Update the user's minted DAI amount
        userMintedDAI[msg.sender] = userMintedDAI[msg.sender].add(
            amountDaiToMint
        );
    }

    // Function to deposit collateral and optionally mint DAI
    function depositCollateral(
        uint256 vid,
        uint256 amount,
        uint256 mintAmount
    ) external {
        IERC20 reserves = _rsvVault[vid].collateral;
        reserves.safeTransferFrom(address(msg.sender), address(this), amount);

        // Calculate the deposit fee
        uint256 feeAmount = amount.mul(DEPOSIT_FEE).div(1);
        uint256 depositAmount = amount.sub(feeAmount);

        uint256 currentVaultBalance = _rsvVault[vid].amount;
        _rsvVault[vid].amount = currentVaultBalance.add(depositAmount);

        if (vid == 0) {
            // Mint DAI tokens 1:1 for reserve 0
            if (mintAmount > 0) {
                // Calculate how much DAI minting this amount of collateral would generate
                uint256 mintedDaiAmount = mintAmount.mul(WEI_VALUE).div(
                    stableColatPrice
                );
                uint256 newHealthFactor = _calculateHealthFactor(
                    userMintedDAI[msg.sender].add(mintedDaiAmount),
                    _getUserCollateralValueInUSD(msg.sender).add(depositAmount)
                );
                require(
                    newHealthFactor >= MIN_HEALTH_FACTOR,
                    "Minting would reduce health factor below 1"
                );

                dai.mint(mintAmount);
                dai.transfer(msg.sender, mintAmount);

                // Log the minted DAI amount for collateral 0
                userMintedDAIByCollateral0[
                    msg.sender
                ] = userMintedDAIByCollateral0[msg.sender].add(mintAmount);
            }
        } else if (vid == 1) {
            // Mint DAI tokens according to the price feed for reserve 1
            if (mintAmount > 0) {
                // Calculate how much DAI minting this amount of collateral would generate
                uint256 mintedDaiAmount = mintAmount.mul(WEI_VALUE).div(
                    lastFetchedPrice
                );
                uint256 newHealthFactor = _calculateHealthFactor(
                    userMintedDAI[msg.sender].add(mintedDaiAmount),
                    _getUserCollateralValueInUSD(msg.sender).add(depositAmount)
                );
                require(
                    newHealthFactor >= MIN_HEALTH_FACTOR,
                    "Minting would reduce health factor below 1"
                );

                dai.mint(mintAmount);
                dai.transfer(msg.sender, mintAmount);

                // Log the minted DAI amount for collateral 1
                userMintedDAIByCollateral1[
                    msg.sender
                ] = userMintedDAIByCollateral1[msg.sender].add(mintAmount);
            }

            // Update user minted DAI
            userMintedDAI[msg.sender] = userMintedDAI[msg.sender].add(
                depositAmount
            );
        }

        // Update total collateral in USD for the specific vid
        _updateTotalCollateralInUSD(vid, depositAmount, true);

        // Update user collateral amount
        userCollateral[msg.sender][vid] = userCollateral[msg.sender][vid].add(
            depositAmount
        );

        emit Deposit(vid, amount);

        if (!existInInvestors(msg.sender)) investors1.push(msg.sender);
    }

    function withdrawCollateral1(uint256 vid, uint256 amount) external {
        IERC20 reserves = _rsvVault[vid].collateral;
        uint256 currentVaultBalance = _rsvVault[vid].amount;
        require(
            currentVaultBalance >= amount,
            "Insufficient collateral balance"
        );
        require(!isLiquidated[msg.sender], "User has been liquidated");

        reserves.safeTransfer(address(msg.sender), amount);
        _rsvVault[vid].amount = currentVaultBalance.sub(amount);
        revertIfHealthFactorIsBroken(msg.sender);

        if (vid == 0) {
            // Burn DAI tokens 1:1 for reserve 0

            uint256 burnAmount = amount.div(2); // 50% of deposit amount
            dai.transferFrom(msg.sender, address(this), burnAmount);
            dai.burn(burnAmount);
        } else if (vid == 1) {
            // Burn DAI tokens according to the price feed for reserve 1
            uint256 burnAmount = amount
                .mul(lastFetchedPrice)
                .div(WEI_VALUE)
                .div(2); // 50% of the calculated burn amount
            dai.transferFrom(msg.sender, address(this), burnAmount);
            dai.burn(burnAmount);
        }

        // Update total collateral in USD for the specific vid
        _updateTotalCollateralInUSD(vid, amount, false);

        // Update user collateral amount
        userCollateral[msg.sender][vid] = userCollateral[msg.sender][vid].sub(
            amount
        );

        emit Withdraw(vid, amount);
    }

    function withdrawCollateralNoBurn(uint256 vid, uint256 amount) external {
        IERC20 reserves = _rsvVault[vid].collateral;
        uint256 currentVaultBalance = _rsvVault[vid].amount;
        require(
            currentVaultBalance >= amount,
            "Insufficient collateral balance"
        );
        require(!isLiquidated[msg.sender], "User has been liquidated");

        // Update user collateral amount
        userCollateral[msg.sender][vid] = userCollateral[msg.sender][vid].sub(
            amount
        );

        reserves.safeTransfer(address(msg.sender), amount);
        _rsvVault[vid].amount = currentVaultBalance.sub(amount);
        revertIfHealthFactorIsBroken(msg.sender);

        emit Withdraw(vid, amount);
    }

    function getCollateralPrice(uint256 vid) internal view returns (uint256) {
        if (vid == 0) {
            return stableColatPrice;
        } else if (vid == 1) {
            return lastFetchedPrice;
        } else {
            revert("Invalid reserve ID");
        }
    }

    function _getUserHealthFactor1(
        address user
    ) external view returns (uint256) {
        uint256 totalCollateralValueInUsd = 0;
        for (uint256 vid = 0; vid < currentReserveId; vid++) {
            uint256 collateralAmount = userCollateral[user][vid];
            uint256 collateralPrice = getCollateralPrice(vid);
            uint256 collateralValueInUsd = collateralAmount
                .mul(collateralPrice)
                .div(WEI_VALUE);
            totalCollateralValueInUsd = totalCollateralValueInUsd.add(
                collateralValueInUsd
            );
        }

        // Assuming lastFetchedPrice is the correct price for the borrowed asset (DAI)
        uint256 totalBorrowedValueInUsd = userMintedDAI[user]
            .mul(lastFetchedPrice)
            .div(WEI_VALUE);

        uint256 healthFactor = totalCollateralValueInUsd.mul(1000).div(
            totalBorrowedValueInUsd
        );
        //userHealthFactors[user] = healthFactor; // Store the health factor for the user
        return healthFactor;
    }

    function mintDai(
        uint256 amountDaiToMint
    ) public moreThanZero(amountDaiToMint) nonReentrant {
        // Calculate the equivalent collateral amount based on the lastFetchedPrice
        uint256 equivalentCollateral = userCollateral[msg.sender][1]
            .mul(lastFetchedPrice)
            .div(1e18);

        // Ensure the user has enough collateral to cover the minted DAI
        require(
            userMintedDAIByCollateral1[msg.sender] >= equivalentCollateral,
            "Insufficient collateral"
        );

        // Update the user's DAI and collateral balances
        userMintedDAI[msg.sender] = userMintedDAI[msg.sender].add(
            amountDaiToMint
        );
        userMintedDAIByCollateral1[msg.sender] = userMintedDAIByCollateral1[
            msg.sender
        ].sub(equivalentCollateral);

        // Subtract the collateral to be removed from the user's total collateral of the respective reserve
        userCollateral[msg.sender][1] = userCollateral[msg.sender][1].sub(
            amountDaiToMint / lastFetchedPrice
        );

        // Check health factor after the update
        revertIfHealthFactorIsBroken(msg.sender);

        try dai.mint(amountDaiToMint) {
            // Minting successful, transfer the minted DAI tokens to the user
            dai.transfer(msg.sender, amountDaiToMint);
        } catch Error(string memory reason) {
            revert(reason);
        } catch {
            revert("Mint Failed");
        }
    }

    function burnUusd(uint256 amount) external moreThanZero(amount) {
        _burnUusd(amount, msg.sender, msg.sender);
    }

    function liquidate(
        uint256 vid,
        address user,
        uint256 debtToCover
    ) external moreThanZero(debtToCover) nonReentrant {
        require(!isLiquidated[user], "User has been liquidated");
        require(
            debtToCover <= userMintedDAI[user],
            "Debt to cover exceeds user's borrow balance"
        );

        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert("Health Factor is Ok");
        }

        IERC20 reserves = _rsvVault[vid].collateral;
        reserves.safeTransfer(address(msg.sender), debtToCover);

        // Ensure the vault has sufficient collateral for liquidation
        uint256 currentVaultBalance = _rsvVault[vid].amount;
        require(
            currentVaultBalance >= debtToCover,
            "Insufficient collateral balance"
        );

        // Convert lastFetchedPrice to wei
        uint256 unstableColPriceWei = lastFetchedPrice * WEI_VALUE;

        // Calculate the collateral value needed for liquidation at lastFetchedPrice in wei
        uint256 collateralToRecover = debtToCover.mul(WEI_VALUE).div(
            unstableColPriceWei
        );
        uint256 bonusCollateral = collateralToRecover
            .mul(LIQUIDATION_BONUS)
            .div(100);
        collateralToRecover = collateralToRecover.add(bonusCollateral);

        // Update the user's liquidation data
        userLiquidationData[user][vid] = LiquidationData(
            debtToCover,
            collateralToRecover
        );

        // Burn Uusd equal to debtToCover
        _burnUusd(debtToCover, user, msg.sender);

        // Transfer the collateral back to the liquidator
        _redeemCollateral(vid, collateralToRecover, user, msg.sender);

        // Update user borrowed balance and liquidation status
        userMintedDAI[user] = userMintedDAI[user].sub(debtToCover);
        isLiquidated[user] = true;

        // Subtract the collateral to be removed from the user's total collateral of the respective reserve
        userCollateral[user][vid] = userCollateral[user][vid].sub(
            collateralToRecover
        );

        // Update total collateral in USD for the specific vid
        _updateTotalCollateralInUSD(vid, collateralToRecover, false);

        uint256 endingUserHealthFactor = _healthFactor(user);

        // This conditional should never hit, but just in case
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert("Health Factor Not Improved");
        }

        revertIfHealthFactorIsBroken(msg.sender);
    }

    // Function to perform the liquidation
    function liquidate1(
        uint256 vid,
        address user,
        uint256 debtToCover
    ) external moreThanZero(debtToCover) nonReentrant {
        IERC20 collateralToken = _rsvVault[vid].collateral;

        // If covering 100 DSC, we need $100 of collateral
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(debtToCover);

        // And give them a 10% bonus
        // So we are giving the liquidator $110 of WETH for 100 DSC
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // And sweep extra amounts into a treasury
        uint256 bonusCollateral = (tokenAmountFromDebtCovered *
            LIQUIDATION_BONUS) / 100;

        // Burn DSC equal to debtToCover
        _burnUusd(debtToCover, user, msg.sender);

        // Transfer the collateral back to the liquidator
        // _redeemCollateral(vid, collateralToRecover, user, msg.sender);
        collateralToken.safeTransfer(
            address(msg.sender),
            tokenAmountFromDebtCovered + bonusCollateral
        );
    }

    // Function to perform the liquidation
    function liquidate2(
        uint256 vid,
        address user,
        uint256 debtToCover
    ) external moreThanZero(debtToCover) nonReentrant {
        IERC20 collateralToken = _rsvVault[vid].collateral;

        // If covering 100 DAI, we need $100 of collateral
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(debtToCover);

        // And give them a 10% bonus
        // So we are giving the liquidator $110 of WETH for 100 DSC
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // And sweep extra amounts into a treasury
        uint256 bonusCollateral = (tokenAmountFromDebtCovered *
            LIQUIDATION_BONUS) / 100;

        // Burn DAI equal to debtToCover
        _burnUusd(debtToCover, user, msg.sender);

        // Transfer the collateral back to the liquidator
        // _redeemCollateral(vid, collateralToRecover, user, msg.sender);
        collateralToken.safeTransfer(
            address(msg.sender),
            tokenAmountFromDebtCovered + bonusCollateral
        );

        // Update the user's liquidation data
        userLiquidationData[user][vid] = LiquidationData(
            debtToCover,
            tokenAmountFromDebtCovered + bonusCollateral
        );

        // Update user borrowed balance and liquidation status
        userMintedDAI[user] = userMintedDAI[user].sub(debtToCover);

        // Subtract the collateral to be removed from the user's total collateral of the respective reserve
        userCollateral[user][vid] = userCollateral[user][vid].sub(
            tokenAmountFromDebtCovered + bonusCollateral
        );

        // Update total collateral in USD for the specific vid
        _updateTotalCollateralInUSD(
            vid,
            tokenAmountFromDebtCovered + bonusCollateral,
            false
        );

        isLiquidated[user] = true;
    }

    /*
    function liquidate(uint256 vid, address user, uint256 debtToCover) external moreThanZero(debtToCover) nonReentrant {
        require(!isLiquidated[user], "User has been liquidated");
        require(debtToCover <= userMintedDAI[user], "Debt to cover exceeds user's borrow balance");

        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert("Health Factor is Ok");
        }

        // If covering 100 DSC, we need $100 of collateral
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(debtToCover);
        // Apply the liquidation discount
        uint256 bonusCollateral = tokenAmountFromDebtCovered.mul(LIQUIDATION_BONUS).div(100);
        // Calculate the total collateral to recover (debtToCover + bonusCollateral)
        uint256 collateralToRecover = tokenAmountFromDebtCovered.add(bonusCollateral);

        // Update the user's liquidation data
        userLiquidationData[user][vid] = LiquidationData(debtToCover, collateralToRecover);

        // Burn DSC equal to debtToCover
        dai.burn(debtToCover);

        // Transfer the collateral back to the liquidator
        _redeemCollateral(vid, collateralToRecover, user, msg.sender);

        // Update user borrowed balance and liquidation status
        userMintedDAI[user] = userMintedDAI[user].sub(debtToCover);
        isLiquidated[user] = true;

        uint256 endingUserHealthFactor = _healthFactor(user);
        // This conditional should never hit, but just in case
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert("Health Factor Not Improved");
        }

        revertIfHealthFactorIsBroken(msg.sender);
    }

*/

    /*
     * @param Vid: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
     * @param amountDaiToBurn: The amount of DAI you want to burn
     * @notice This function will withdraw your collateral and burn DAI in one transaction
     */

    // Function to redeem collateral for DAI
    function redeemCollateralForUusd(
        uint256 vid,
        uint256 amountCollateral,
        uint256 amountDaiToBurn
    ) external moreThanZero(amountCollateral) {
        // Burn the specified amount of DAI tokens from the user
        _burnUusd(amountDaiToBurn, msg.sender, msg.sender);

        // Redeem the specified amount of collateral for the user
        IERC20 collateralToken = _rsvVault[vid].collateral;

        collateralToken.safeTransfer(msg.sender, amountCollateral);

        // Update total collateral in USD for the specific vid
        _updateTotalCollateralInUSD(vid, amountCollateral, false);

        // Update user collateral amount
        userCollateral[msg.sender][vid] = userCollateral[msg.sender][vid].sub(
            amountCollateral
        );

        // You can optionally include the following line if you want to check the health factor after redemption
        // revertIfHealthFactorIsBroken(msg.sender);
    }

    // Function to redeem collateral
    function redeemCollateral(
        uint256 vid,
        uint256 amountCollateral
    ) external moreThanZero(amountCollateral) nonReentrant {
        IERC20 collateralToken = _rsvVault[vid].collateral;
        uint256 currentVaultBalance = _rsvVault[vid].amount;
        require(
            currentVaultBalance >= amountCollateral,
            "Insufficient collateral balance"
        );
        require(!isLiquidated[msg.sender], "User has been liquidated");

        collateralToken.safeTransfer(address(msg.sender), amountCollateral);

        // Redeem the specified amount of collateral for the user
        // _redeemCollateral(vid, amountCollateral, msg.sender, msg.sender);
        _rsvVault[vid].amount = currentVaultBalance.sub(amountCollateral);

        // Check and revert if the user's health factor is below the minimum required

        revertIfHealthFactorIsBroken(msg.sender);

        // Update user collateral amount
        userCollateral[msg.sender][vid] = userCollateral[msg.sender][vid].sub(
            amountCollateral
        );

        emit CollateralRedeemed(
            address(this),
            msg.sender,
            address(collateralToken),
            amountCollateral
        );
    }

    function _redeemCollateral(
        uint256 vid,
        uint256 amountCollateral,
        address from,
        address to
    ) private {
        IERC20 collateralToken = _rsvVault[vid].collateral;
        s_collateralDeposited[from][
            address(collateralToken)
        ] -= amountCollateral;
        emit CollateralRedeemed(
            from,
            to,
            address(collateralToken),
            amountCollateral
        );

        // Transfer the collateral to the liquidator
        collateralToken.safeTransfer(to, amountCollateral);

        // Check if the transfer was successful
        require(
            collateralToken.balanceOf(to) >= amountCollateral,
            "Transfer Failed"
        );
    }

    function getUserCollateralValueInUSD(
        address user
    ) external view returns (uint256) {
        uint256 totalCollateralValueInUSD = 0;
        for (uint256 vid = 0; vid < currentReserveId; vid++) {
            uint256 collateralAmount = userCollateral[user][vid];
            uint256 collateralPrice = getCollateralPrice(vid);

            // Calculate the collateral value in USD
            uint256 collateralValueInUSD = collateralAmount
                .mul(collateralPrice)
                .div(WEI_VALUE);
            totalCollateralValueInUSD = totalCollateralValueInUSD.add(
                collateralValueInUSD
            );
        }
        return totalCollateralValueInUSD;
    }

    function _burnUusd(
        uint256 amountDaiToBurn,
        address onBehalfOf,
        address uusdFrom
    ) private {
        userMintedDAI[onBehalfOf] -= amountDaiToBurn;

        bool success = dai.transferFrom(
            uusdFrom,
            address(this),
            amountDaiToBurn
        );
        // This conditional is hypothetically unreachable
        if (!success) {
            revert("Transfer Failed");
        }
        dai.burn(amountDaiToBurn);
    }

    //////////////////////////////
    // Private & Internal View & Pure Functions
    //////////////////////////////

    function _getAccountInformation(
        address user
    )
        private
        view
        returns (uint256 totalUusdMinted, uint256 collateralValueInUsd)
    {
        totalUusdMinted = userMintedDAI[user];

        for (uint256 vid = 0; vid < currentReserveId; vid++) {
            uint256 collateralAmount = userCollateral[user][vid];
            uint256 collateralPrice = getCollateralPrice(vid);

            // Calculate the collateral value in USD
            uint256 collateralValueInUSD = collateralAmount
                .mul(collateralPrice)
                .div(WEI_VALUE);
            collateralValueInUsd = collateralValueInUsd.add(
                collateralValueInUSD
            );
        }
    }

    function _getUserCollateralValueInUSD(
        address user
    ) private view returns (uint256) {
        uint256 totalCollateralValueInUSD = 0;
        for (uint256 vid = 0; vid < currentReserveId; vid++) {
            uint256 collateralAmount = userCollateral[user][vid];
            uint256 collateralPrice = getCollateralPrice(vid);

            // Calculate the collateral value in USD
            uint256 collateralValueInUSD = collateralAmount
                .mul(collateralPrice)
                .div(WEI_VALUE);
            totalCollateralValueInUSD = totalCollateralValueInUSD.add(
                collateralValueInUSD
            );
        }
        return totalCollateralValueInUSD;
    }

    function _healthFactor(address user) private view returns (uint256) {
        (
            uint256 totalUusdMinted,
            uint256 collateralValueInUsd
        ) = _getAccountInformation(user);
        return _calculateHealthFactor(totalUusdMinted, collateralValueInUsd);
    }

    function _calculateHealthFactor(
        uint256 totalUusdMinted,
        uint256 collateralValueInUsd
    ) internal pure returns (uint256) {
        if (totalUusdMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd *
            LIQUIDATION_THRESHOLD) / 100;
        return (collateralAdjustedForThreshold * 1e18) / totalUusdMinted;
    }

    function revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DAI__BreaksHealthFactor(userHealthFactor);
        }
    }

    function getTokenAmountFromUsd(
        uint256 usdAmountInWei
    ) public view returns (uint256) {
        return 1;
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    // Function to get the user's health factor
    function getHealthFactor(address user) external view returns (uint256) {
        (
            uint256 totalUusdMinted,
            uint256 collateralValueInUsd
        ) = _getAccountInformation(user);
        return _calculateHealthFactor(totalUusdMinted, collateralValueInUsd);
    }

    function getLiquidationPrice(address user) external view returns (uint256) {
        (
            uint256 totalUusdMinted,
            uint256 collateralValueInUsd
        ) = _getAccountInformation(user);

        if (totalUusdMinted == 0) {
            return 0; // No DAI minted, return 0 as there's no debt
        }

        // Calculate the health factor
        uint256 healthFactor = _calculateHealthFactor(
            totalUusdMinted,
            collateralValueInUsd
        );

        // Calculate the liquidation price in wei
        uint256 liquidationPrice = lastFetchedPrice.mul(WEI_VALUE).div(
            healthFactor
        );

        return liquidationPrice;
    }

    // Function to calculate the collateralization ratio for a user
    function getCollateralizationRatio(
        address user
    ) external view returns (uint256) {
        (
            uint256 totalUusdMinted,
            uint256 collateralValueInUsd
        ) = _getAccountInformation(user);
        uint256 healthFactor = _calculateHealthFactor(
            totalUusdMinted,
            collateralValueInUsd
        );

        // Collateralization ratio is the inverse of the health factor
        if (healthFactor == type(uint256).max) {
            // If health factor is infinite, set collateralization ratio to 0
            return 0;
        } else {
            //return ((WEI_VALUE.mul(1e18) + healthFactor).div(healthFactor)).mul(100);
            return collateralValueInUsd.div(totalUusdMinted);
        }
    }

    function _calculateCollateralizationRatio(
        uint256 totalUusdMinted,
        uint256 collateralValueInUsd
    ) internal pure returns (uint256) {
        if (totalUusdMinted == 0) return type(uint256).max;
        return collateralValueInUsd.mul(1).div(totalUusdMinted);
    }

    function calculateMaxWithdrawAmounts(
        address user
    )
        external
        view
        returns (uint256 maxStableWithdraw, uint256 maxUnstableWithdraw)
    {
        // Get the user's current collateral values
        (
            uint256 totalUusdMinted,
            uint256 collateralValueInUsd
        ) = _getAccountInformation(user);

        // Calculate the collateralization ratio
        uint256 collateralizationRatio = _calculateCollateralizationRatio(
            totalUusdMinted,
            collateralValueInUsd
        );

        // Calculate the amount of stable and unstable collaterals that can be withdrawn before health factor is 1
        maxStableWithdraw = 0;
        maxUnstableWithdraw = 0;

        if (collateralizationRatio > WEI_VALUE) {
            // Health factor is already above 1, no collateral can be withdrawn
            return (maxStableWithdraw, maxUnstableWithdraw);
        }

        // Calculate the target collateral value for a health factor of 1
        uint256 targetCollateralValue = totalUusdMinted.mul(WEI_VALUE).div(
            MIN_HEALTH_FACTOR
        );

        // Calculate the current excess collateral (collateral - targetCollateral)
        uint256 excessCollateral = collateralValueInUsd > targetCollateralValue
            ? collateralValueInUsd - targetCollateralValue
            : 0;

        if (excessCollateral > 0) {
            // Calculate the maximum amount of stable collateral that can be withdrawn
            maxStableWithdraw = excessCollateral.mul(1e18).div(
                stableColatPrice
            );

            // Calculate the maximum amount of unstable collateral that can be withdrawn
            maxUnstableWithdraw = excessCollateral.mul(1e18).div(
                lastFetchedPrice
            );
        }
    }

    // if the address exists in current investors list
    function existInInvestors(address investor) public view returns (bool) {
        for (uint256 j = 0; j < investors1.length; j++) {
            if (investors1[j] == investor) {
                return true;
            }
        }
        return false;
    }

    function getInvestors() public view returns (address[] memory) {
        return investors1;
    }
}
