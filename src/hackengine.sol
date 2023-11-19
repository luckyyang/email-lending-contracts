 // SPDX-License-Identifier: MIT LICENSE
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@chainlink/contracts/src/v0.6/interfaces/AggregatorV3Interface.sol";
import "./uusd1.sol";
import "./IC.sol";

contract hackFinal is Ownable, ReentrancyGuard, AccessControl {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;



    
    error UUSDEngine__BreaksHealthFactor(uint256 healthFactorValue);
    

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

    UUSD private uusd;
    AggregatorV3Interface private priceOracle;
    IChronicle private pO;
    address private reserveContract;
    address public datafeed;
    uint256 public supplyChangeCount;
    uint256 public stableColatPrice = 1e18;
    uint256 public stableColatAmount;
    uint256 private constant COL_PRICE_TO_WEI = 1e10;
    uint256 private constant WEI_VALUE = 1e18;
    uint256 public unstableColatAmount;
    uint256 public unstableColPrice;
    uint256 public stableColatPriceZar;
    uint256 private constant DEPOSIT_FEE = 100; // 0.1% fee
    uint256 private constant COLLATERALIZATION_RATIO = 150; // 150% collateralization ratio
    uint256 private constant LIQUIDATION_DISCOUNT = 10; // 10% discount on liquidated assets


    uint256 private constant LIQUIDATION_THRESHOLD =  67; // (150/100)*0.67=1   150% over-collateralized 
                                                          // 50 : This means you need to be 200% over-collateralized 
    uint256 private constant LIQUIDATION_BONUS = 10; // This means you get assets at a 10% discount when liquidating
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant FEED_PRECISION = 1e8;
    // Define the minimum health factor required for liquidation
    uint256 constant MIN_LIQUIDATION_HEALTH_FACTOR = 0.5 * 1e18;

    address public treasuryWallet;
    uint public lastFetchedPrice;
    address[] public investors1;




    // Mapping to store liquidation data for each user and each collateral type (VID)
    mapping(address => mapping(uint256 => LiquidationData)) public userLiquidationData;
    mapping(uint256 => ReserveVault) public _rsvVault;
    mapping(address => uint256) public userMintedUUSD;
    mapping(address => mapping(uint256 => uint256)) public userCollateral;
    //mapping(address => uint256) public userBorrowed;
    mapping(address => bool) public isLiquidated;
    mapping(address => mapping(address => uint256)) private s_collateralDeposited;

    // Mapping to store user minted UUSD amounts for each VID (for VID 0)
    mapping(address => uint256) public userMintedUUSDByCollateral0;

    // Mapping to store user minted UUSD amounts for each VID (for VID 1)
    mapping(address => uint256) public userMintedUUSDByCollateral1;

    // Mapping to store total collateral in USD by the contract for vid 0 and 1
    mapping(uint256 => uint256) public totalCollateralInUSD;

    mapping(address => uint256) public userHealthFactors;
    mapping(address => bool) public isBelowHealthFactorOne;





    // Event to signal users with unhealthy health factor
    event UnhealthyHealthFactor(address indexed user, uint256 healthFactor);
    event Withdraw(uint256 indexed vid, uint256 amount);
    event Deposit(uint256 indexed vid, uint256 amount);
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address token, uint256 amount); // if redeemFrom != redeemedTo, then it was liquidated
    event Liquidate(address indexed user, uint256 indexed vid, uint256 amount, uint256 liquidationAmount);

    


    ///////////////////
    // Modifiers
    ///////////////////

    // Modifier to check if the user's health factor is good
    modifier hasGoodHealthFactor(address user) {
        require(_healthFactor(user) >= MIN_HEALTH_FACTOR, "UUSDEngine__HealthFactorNotOk");
        _;
    }

    modifier moreThanZero(uint256 amount) {
        require(amount > 0, "UUSDEngine__NeedsMoreThanZero");
        _;
    }


    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant GOVERN_ROLE = keccak256("GOVERN_ROLE");

    constructor(UUSD _uusd) {
        uusd = _uusd;
        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _setupRole(MANAGER_ROLE, _msgSender());
    }


  




    



  

    function checkReserveContract(IERC20 _collateral) internal view {
        for (uint256 i; i < currentReserveId; i++) {
            require(_rsvVault[i].collateral != _collateral, "Collateral Address Already Added");
        }
    }

    function addReserveVault(IERC20 _collateral) external {
        require(hasRole(MANAGER_ROLE, _msgSender()), "Not allowed");
        checkReserveContract(_collateral);
        _rsvVault[currentReserveId].collateral = _collateral;
        currentReserveId++;
    }

    function setDataFeedAddress(address contractaddress) external {
        require(hasRole(GOVERN_ROLE, _msgSender()), "Not allowed");
        datafeed = contractaddress;
        priceOracle = AggregatorV3Interface(datafeed);
    }

    function fetchColPrice() external nonReentrant {
        require(hasRole(GOVERN_ROLE, _msgSender()), "Not allowed");
        (, uint256 price, , , ) = priceOracle.latestRoundData();
        uint256 value = price.mul(COL_PRICE_TO_WEI);
        unstableColPrice = value;
    }



    // Function to update the total collateral in USD for a specific vid
    function _updateTotalCollateralInUSD(uint256 vid, uint256 amount, bool isDeposit) internal {
        uint256 currentTotalCollateral = totalCollateralInUSD[vid];
        if (isDeposit) {
            totalCollateralInUSD[vid] = currentTotalCollateral.add(amount);
        } else {
            totalCollateralInUSD[vid] = currentTotalCollateral.sub(amount);
        }
    }


    function mintUusdIfHealthy(uint256 amountUusdToMint) public moreThanZero(amountUusdToMint) nonReentrant hasGoodHealthFactor(msg.sender) {
        uint256 totalCollateralValueInUSD = 0;
        for (uint256 vid = 0; vid < currentReserveId; vid++) {
            uint256 collateralAmount = userCollateral[msg.sender][vid];
            uint256 collateralPrice = getCollateralPrice(vid);

            // Calculate the collateral value in USD
            uint256 collateralValueInUSD = collateralAmount.mul(collateralPrice).div(WEI_VALUE);
            totalCollateralValueInUSD = totalCollateralValueInUSD.add(collateralValueInUSD);
        }

        // Calculate the total borrowed value in USD (total minted UUSD)
        uint256 totalBorrowedValueInUSD = userMintedUUSD[msg.sender];

        // Check if the user has enough collateral to mint UUSD
        require(totalCollateralValueInUSD >= totalBorrowedValueInUSD, "UUSDEngine__NotEnoughCollateral");

        // Mint UUSD tokens
        uusd.mint(amountUusdToMint);

        // Transfer the minted UUSD tokens to the user
        uusd.transfer(msg.sender, amountUusdToMint);

        // Update the user's minted UUSD amount
        userMintedUUSD[msg.sender] = userMintedUUSD[msg.sender].add(amountUusdToMint);

        

    }


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




    


    // Function to deposit collateral and mint UUSD
    function depositCollateral(uint256 vid, uint256 amount, uint256 mintAmount) external {
        IERC20 reserves = _rsvVault[vid].collateral;
        reserves.safeTransferFrom(address(msg.sender), address(this), amount);

        // Calculate the deposit fee
        uint256 feeAmount = amount.mul(DEPOSIT_FEE).div(10000); // 0.01% fee
        uint256 depositAmount = amount.sub(feeAmount);

        uint256 currentVaultBalance = _rsvVault[vid].amount;
        _rsvVault[vid].amount = currentVaultBalance.add(depositAmount);

         // Update user collateral amount
        userCollateral[msg.sender][vid] = userCollateral[msg.sender][vid].add(depositAmount);


        if (vid == 0) {
            // Mint UUSD tokens 1:1 for reserve 0
            if (mintAmount > 0) {
                // Calculate how much UUSD minting this amount of collateral would generate
                uint256 mintedUusdAmount = mintAmount.mul(WEI_VALUE).div(stableColatPrice);
                uint256 newHealthFactor = _calculateHealthFactor(
                    userMintedUUSD[msg.sender].add(mintedUusdAmount),
                    _getUserCollateralValueInUSD(msg.sender).add(depositAmount)
                );
                require(newHealthFactor >= MIN_HEALTH_FACTOR, "Minting would reduce health factor below 1");

                uusd.mint(mintAmount);
                uusd.transfer(msg.sender, mintAmount);
                
                // Log the minted UUSD amount for collateral 0
                userMintedUUSDByCollateral0[msg.sender] = userMintedUUSDByCollateral0[msg.sender].add(mintAmount);
            }
        } else if (vid == 1) {
            // Mint UUSD tokens according to the price feed for reserve 1
            if (mintAmount > 0) {
                // Calculate how much UUSD minting this amount of collateral would generate
                uint256 mintedUusdAmount = mintAmount.mul(WEI_VALUE).div(unstableColPrice);
                uint256 newHealthFactor = _calculateHealthFactor(
                    userMintedUUSD[msg.sender].add(mintedUusdAmount),
                    _getUserCollateralValueInUSD(msg.sender).add(depositAmount)
                );
                require(newHealthFactor >= MIN_HEALTH_FACTOR, "Minting would reduce health factor below 1");

                uusd.mint(mintAmount);
                uusd.transfer(msg.sender, mintAmount);

                // Log the minted UUSD amount for collateral 1
                userMintedUUSDByCollateral1[msg.sender] = userMintedUUSDByCollateral1[msg.sender].add(mintAmount);
            }

            // Update user minted UUSD
            userMintedUUSD[msg.sender] = userMintedUUSD[msg.sender].add(depositAmount);
        }

        // Update total collateral in USD for the specific vid
        _updateTotalCollateralInUSD(vid, depositAmount, true);

        

       
        emit Deposit(vid, amount);

        if(!existInInvestors(msg.sender)) investors1.push(msg.sender);
    }

















    function withdrawCollateral(uint256 vid, uint256 amount) external nonReentrant {
        IERC20 reserves = _rsvVault[vid].collateral;
        uint256 currentVaultBalance = _rsvVault[vid].amount;
        require(currentVaultBalance >= amount, "Insufficient collateral balance");
        require(!isLiquidated[msg.sender], "User has been liquidated");

        // Update user collateral amount (effects)
        userCollateral[msg.sender][vid] = userCollateral[msg.sender][vid].sub(amount);

        // Update total collateral in USD for the specific vid (effects)
        _updateTotalCollateralInUSD(vid, amount, false);

        // Perform checks and effects before external interactions
        // This prevents reentrancy attacks

        // Transfer collateral to the user (external interaction)
        reserves.safeTransfer(address(msg.sender), amount);

        // Update the vault balance (effects)
        _rsvVault[vid].amount = currentVaultBalance.sub(amount);

        // Revert if health factor is broken (checks)
        revertIfHealthFactorIsBroken(msg.sender);

        // Perform stable burn based on the vid (effects)
        if (vid == 0) {
            uint256 burnAmount = amount.div(2); // 50% of deposit amount
            uusd.transferFrom(msg.sender, address(this), burnAmount);
            uusd.burn(burnAmount);
        } else if (vid == 1) {
            uint256 burnAmount = amount.mul(unstableColPrice).div(WEI_VALUE).div(2); // 50% of the calculated burn amount
            uusd.transferFrom(msg.sender, address(this), burnAmount);
            uusd.burn(burnAmount);
        }

        emit Withdraw(vid, amount);
    }



    function withdrawCollateralNoBurn(uint256 vid, uint256 amount) external {
        IERC20 reserves = _rsvVault[vid].collateral;
        uint256 currentVaultBalance = _rsvVault[vid].amount;
        require(currentVaultBalance >= amount, "Insufficient collateral balance");
        require(!isLiquidated[msg.sender], "User has been liquidated");

        // Update user collateral amount
        userCollateral[msg.sender][vid] = userCollateral[msg.sender][vid].sub(amount);

        reserves.safeTransfer(address(msg.sender), amount);
        _rsvVault[vid].amount = currentVaultBalance.sub(amount);
        revertIfHealthFactorIsBroken(msg.sender);


        

        emit Withdraw(vid, amount);
    }


    function withdrawCollateralGorvern(uint256 vid, uint256 amount) external {
        require(hasRole(GOVERN_ROLE, _msgSender()), "Not allowed");
        IERC20 reserves = _rsvVault[vid].collateral;
        uint256 currentVaultBalance = _rsvVault[vid].amount;
        require(currentVaultBalance >= amount, "Insufficient collateral balance");
        require(!isLiquidated[msg.sender], "User has been liquidated");

        reserves.safeTransfer(address(msg.sender), amount);
        _rsvVault[vid].amount = currentVaultBalance.sub(amount);
        

        emit Withdraw(vid, amount);
    }
    

   

    function getCollateralPrice(uint256 vid) internal view returns (uint256) {
        if (vid == 0) {
            return stableColatPrice;
        } else if (vid == 1) {
            return unstableColPrice;
        } else {
            revert("Invalid reserve ID");
        }
    }



    function _getUserHealthFactor1(address user) external view returns (uint256) {
        uint256 totalCollateralValueInUsd = 0;
        for (uint256 vid = 0; vid < currentReserveId; vid++) {
            uint256 collateralAmount = userCollateral[user][vid];
            uint256 collateralPrice = getCollateralPrice(vid);
            uint256 collateralValueInUsd = collateralAmount.mul(collateralPrice).div(WEI_VALUE);
            totalCollateralValueInUsd = totalCollateralValueInUsd.add(collateralValueInUsd);
        }

        // Assuming unstableColPrice is the correct price for the borrowed asset (UUSD)
        uint256 totalBorrowedValueInUsd = userMintedUUSD[user].mul(unstableColPrice).div(WEI_VALUE);

        uint256 healthFactor = totalCollateralValueInUsd.mul(1000).div(totalBorrowedValueInUsd);
        //userHealthFactors[user] = healthFactor; // Store the health factor for the user
        return healthFactor;
    }



    
    function mintUusd(uint256 amountUusdToMint) public moreThanZero(amountUusdToMint) nonReentrant {
        // Calculate the equivalent collateral amount based on the unstableColPrice
        uint256 equivalentCollateral = userCollateral[msg.sender][1].mul(unstableColPrice).div(1e18);

        // Ensure the user has enough collateral to cover the minted UUSD
        require(userMintedUUSDByCollateral1[msg.sender] >= equivalentCollateral, "Insufficient collateral");

        // Update the user's UUSD and collateral balances
        userMintedUUSD[msg.sender] = userMintedUUSD[msg.sender].add(amountUusdToMint);
        userMintedUUSDByCollateral1[msg.sender] = userMintedUUSDByCollateral1[msg.sender].sub(equivalentCollateral);

        // Subtract the collateral to be removed from the user's total collateral of the respective reserve
        userCollateral[msg.sender][1] = userCollateral[msg.sender][1].sub(amountUusdToMint/unstableColPrice);

        // Check health factor after the update
        revertIfHealthFactorIsBroken(msg.sender);

        try uusd.mint(amountUusdToMint) {
            // Minting successful, transfer the minted UUSD tokens to the user
            uusd.transfer(msg.sender, amountUusdToMint);
        } catch Error(string memory reason) {
            revert(reason);
        } catch {
            revert("Mint Failed");
        }
    }


    function burnUusd(uint256 amount) external moreThanZero(amount) {
        _burnUusd(amount, msg.sender, msg.sender);
    }








    function liquidate(uint256 vid, address user, uint256 debtToCover) external moreThanZero(debtToCover) nonReentrant {
        

        require(!isLiquidated[user], "User has been liquidated");
       // require(debtToCover <= userMintedUUSD[user], "Debt to cover exceeds user's borrow balance");

        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert("Health Factor Ok");
        }

        IERC20 reserves = _rsvVault[vid].collateral;
        reserves.safeTransfer(address(msg.sender), debtToCover);

        // Ensure the vault has sufficient collateral for liquidation
        uint256 currentVaultBalance = _rsvVault[vid].amount;
        require(currentVaultBalance >= debtToCover, "Insufficient collateral balance");

        // Convert unstableColPrice to wei
        uint256 unstableColPriceWei = unstableColPrice * WEI_VALUE;

        // Calculate the collateral value needed for liquidation at unstableColPrice in wei
        uint256 collateralToRecover = debtToCover.mul(WEI_VALUE).div(unstableColPriceWei);
        uint256 bonusCollateral = collateralToRecover.mul(LIQUIDATION_BONUS).div(100);
        collateralToRecover = collateralToRecover.add(bonusCollateral);

        // Update the user's liquidation data
        userLiquidationData[user][vid] = LiquidationData(debtToCover, collateralToRecover);

        // Burn Uusd equal to debtToCover
        _burnUusd(debtToCover, user, msg.sender);

        // Transfer the collateral back to the liquidator
        _redeemCollateral(vid, collateralToRecover, user, msg.sender);

        // Update user borrowed balance and liquidation status
        userMintedUUSD[user] = userMintedUUSD[user].sub(debtToCover);
        isLiquidated[user] = true;

        // Subtract the collateral to be removed from the user's total collateral of the respective reserve
        userCollateral[user][vid] = userCollateral[user][vid].sub(collateralToRecover);

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
    function liquidate2(uint256 vid, address user, uint256 debtToCover) external moreThanZero(debtToCover) nonReentrant {
        IERC20 collateralToken = _rsvVault[vid].collateral;

        // If covering 100 UUSD, we need $100 of collateral
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(debtToCover);

        // And give them a 10% bonus
        // So we are giving the liquidator $110 of WETH for 100 DSC
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // And sweep extra amounts into a treasury
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / 100;

        
  
        // Burn UUSD equal to debtToCover
        _burnUusd(debtToCover, user, msg.sender);

    
        // Transfer the collateral back to the liquidator
        // _redeemCollateral(vid, collateralToRecover, user, msg.sender);
        collateralToken.safeTransfer(address(msg.sender), tokenAmountFromDebtCovered + bonusCollateral);


        // Update the user's liquidation data
        userLiquidationData[user][vid] = LiquidationData(debtToCover, tokenAmountFromDebtCovered + bonusCollateral);

        // Update user borrowed balance and liquidation status
        userMintedUUSD[user] = userMintedUUSD[user].sub(debtToCover);

        // Subtract the collateral to be removed from the user's total collateral of the respective reserve
        userCollateral[user][vid] = userCollateral[user][vid].sub(tokenAmountFromDebtCovered + bonusCollateral);

        // Update total collateral in USD for the specific vid
        _updateTotalCollateralInUSD(vid, tokenAmountFromDebtCovered + bonusCollateral, false);

        isLiquidated[user] = true;


    }



    // Function for users with unhealthy health factor to handle the situation
    function handleUnhealthyHealthFactor() external {
        uint256 userHealthFactor = _healthFactor(msg.sender);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            // Emit an event to indicate that the user's health factor is below the threshold
            emit UnhealthyHealthFactor(msg.sender, userHealthFactor);

            // You can add additional logic or actions here to handle the unhealthy health factor
            // For example, notify the user, restrict further actions, or assist the user in improving the health factor.
        }
    }






    /*
     * @param Vid: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
     * @param amountUusdToBurn: The amount of UUSD you want to burn
     * @notice This function will withdraw your collateral and burn UUSD in one transaction
     */

    // Function to redeem collateral for UUSD
    function redeemCollateralForUusd(uint256 vid, uint256 amountCollateral, uint256 amountUusdToBurn)  external  moreThanZero(amountCollateral)  {
        // Burn the specified amount of UUSD tokens from the user
        _burnUusd(amountUusdToBurn, msg.sender, msg.sender);

        // Redeem the specified amount of collateral for the user
        IERC20 collateralToken = _rsvVault[vid].collateral;
        
        collateralToken.safeTransfer(msg.sender, amountCollateral);

        // Update total collateral in USD for the specific vid
        _updateTotalCollateralInUSD(vid, amountCollateral, false);

        // Update user collateral amount
        userCollateral[msg.sender][vid] = userCollateral[msg.sender][vid].sub(amountCollateral);

        // You can optionally include the following line if you want to check the health factor after redemption
        // revertIfHealthFactorIsBroken(msg.sender);
    }


    // Function to redeem collateral
    function redeemCollateral(uint256 vid, uint256 amountCollateral) external moreThanZero(amountCollateral) nonReentrant {
        IERC20 collateralToken = _rsvVault[vid].collateral;
        uint256 currentVaultBalance = _rsvVault[vid].amount;
        require(currentVaultBalance >= amountCollateral, "Insufficient collateral balance");
        require(!isLiquidated[msg.sender], "User has been liquidated");

        collateralToken.safeTransfer(address(msg.sender), amountCollateral);

        // Redeem the specified amount of collateral for the user
       // _redeemCollateral(vid, amountCollateral, msg.sender, msg.sender);
       _rsvVault[vid].amount = currentVaultBalance.sub(amountCollateral);

        // Check and revert if the user's health factor is below the minimum required
        
        revertIfHealthFactorIsBroken(msg.sender);

        // Update user collateral amount
        userCollateral[msg.sender][vid] = userCollateral[msg.sender][vid].sub(amountCollateral);

        emit CollateralRedeemed( address(this),  msg.sender,  address(collateralToken),  amountCollateral);
    }


   




  
    function _redeemCollateral(uint256 vid, uint256 amountCollateral, address from, address to)  private  {
        IERC20 collateralToken = _rsvVault[vid].collateral;
        s_collateralDeposited[from][address(collateralToken)] -= amountCollateral;
        emit CollateralRedeemed(from, to, address(collateralToken), amountCollateral);

        // Transfer the collateral to the liquidator
        collateralToken.safeTransfer(to, amountCollateral);

        // Check if the transfer was successful
        require(collateralToken.balanceOf(to) >= amountCollateral, "UUSDEngine__TransferFailed");
    }






    function getUserCollateralValueInUSD(address user) external view returns (uint256) {
        uint256 totalCollateralValueInUSD = 0;
        for (uint256 vid = 0; vid < currentReserveId; vid++) {
            uint256 collateralAmount = userCollateral[user][vid];
            uint256 collateralPrice = getCollateralPrice(vid);

            // Calculate the collateral value in USD
            uint256 collateralValueInUSD = collateralAmount.mul(collateralPrice).div(WEI_VALUE);
            totalCollateralValueInUSD = totalCollateralValueInUSD.add(collateralValueInUSD);
        }
        return totalCollateralValueInUSD;
    }


    




    function _burnUusd(uint256 amountUusdToBurn, address onBehalfOf, address uusdFrom) private {
        userMintedUUSD[onBehalfOf] -= amountUusdToBurn;

        bool success = uusd.transferFrom(uusdFrom, address(this), amountUusdToBurn);
        // This conditional is hypothetically unreachable
        if (!success) {
            revert ("UUSDEngine__TransferFailed");
        }
        uusd.burn(amountUusdToBurn);
    }


    //////////////////////////////
    // Private & Internal View & Pure Functions
    //////////////////////////////




    function _getAccountInformation(address user) private view returns (uint256 totalUusdMinted, uint256 collateralValueInUsd) {
        totalUusdMinted = userMintedUUSD[user];

        for (uint256 vid = 0; vid < currentReserveId; vid++) {
            uint256 collateralAmount = userCollateral[user][vid];
            uint256 collateralPrice = getCollateralPrice(vid);

            // Calculate the collateral value in USD
            uint256 collateralValueInUSD = collateralAmount.mul(collateralPrice).div(WEI_VALUE);
            collateralValueInUsd = collateralValueInUsd.add(collateralValueInUSD);
        }
    }


    function _getUserCollateralValueInUSD(address user) private view returns (uint256) {
        uint256 totalCollateralValueInUSD = 0;
        for (uint256 vid = 0; vid < currentReserveId; vid++) {
            uint256 collateralAmount = userCollateral[user][vid];
            uint256 collateralPrice = getCollateralPrice(vid);

            // Calculate the collateral value in USD
            uint256 collateralValueInUSD = collateralAmount.mul(collateralPrice).div(WEI_VALUE);
            totalCollateralValueInUSD = totalCollateralValueInUSD.add(collateralValueInUSD);
        }
        return totalCollateralValueInUSD;
    }



    

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalUusdMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(totalUusdMinted, collateralValueInUsd);
    }







    function _calculateHealthFactor(uint256 totalUusdMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalUusdMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / 100;
        return (collateralAdjustedForThreshold * 1e18) / totalUusdMinted;
    }








    function revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert UUSDEngine__BreaksHealthFactor(userHealthFactor);
        }
    }









    function getTokenAmountFromUsd(uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(datafeed);
        (, uint256 price,,,) = priceFeed.latestRoundData();
        uint256 priceUnsigned = uint256(price); // Convert int256 to uint256

        // $100e18 USD Debt
        // 1 ETH = 2000 USD
        // The returned value from Chainlink will be 2000 * 1e8
        // Most USD pairs have 8 decimals, so we will just pretend they all do
        return ((usdAmountInWei * PRECISION) / (priceUnsigned * ADDITIONAL_FEED_PRECISION));
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
        (uint256 totalUusdMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(totalUusdMinted, collateralValueInUsd);
        // user's liquidation => (current token price / health factor = liquidation price)
        // user's liquidation => minted / (liquidation threshold/100) 
    }


    function isHealthFactorBelowOne(address user) external view returns (bool) {
        return userHealthFactors[user] < 10000; // Health factor below 1 is represented as 10000 (100%) in the contract
    }


    function getLiquidationPrice(address user) external view returns (uint256) {
        (uint256 totalUusdMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        
        if (totalUusdMinted == 0) {
            return 0; // No UUSD minted, return 0 as there's no debt
        }
        
        // Calculate the total borrowed value in USD
       // uint256 totalBorrowedValueInUsd = totalUusdMinted.mul(unstableColPrice).div(WEI_VALUE);
        
        // Calculate the health factor
        uint256 healthFactor = _calculateHealthFactor(totalUusdMinted, collateralValueInUsd);
        
        // Calculate the liquidation price in wei
        uint256 liquidationPrice = unstableColPrice.mul(WEI_VALUE).div(healthFactor);

        return liquidationPrice;
    }


    // Function to calculate the collateralization ratio for a user
    function getCollateralizationRatio(address user) external view returns (uint256) {
        (uint256 totalUusdMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 healthFactor = _calculateHealthFactor(totalUusdMinted, collateralValueInUsd);

        // Collateralization ratio is the inverse of the health factor
        if (healthFactor == type(uint256).max) {
            // If health factor is infinite, set collateralization ratio to 0
            return 0;
        } else {
            //return ((WEI_VALUE.mul(1e18) + healthFactor).div(healthFactor)).mul(100);
            return collateralValueInUsd.div(totalUusdMinted);
        }
    }


    function _calculateCollateralizationRatio(uint256 totalUusdMinted, uint256 collateralValueInUsd) internal pure returns (uint256) {
        if (totalUusdMinted == 0) return type(uint256).max;
        return collateralValueInUsd.mul(1).div(totalUusdMinted);
    }


    

    function calculateMaxWithdrawAmounts(address user) external view returns (uint256 maxStableWithdraw, uint256 maxUnstableWithdraw) {
        // Get the user's current collateral values
        (uint256 totalUusdMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);

        // Calculate the collateralization ratio
        uint256 collateralizationRatio = _calculateCollateralizationRatio(totalUusdMinted, collateralValueInUsd);

        // Calculate the amount of stable and unstable collaterals that can be withdrawn before health factor is 1
        maxStableWithdraw = 0;
        maxUnstableWithdraw = 0;

        if (collateralizationRatio > WEI_VALUE) {
            // Health factor is already above 1, no collateral can be withdrawn
            return (maxStableWithdraw, maxUnstableWithdraw);
        }

        // Calculate the target collateral value for a health factor of 1
        uint256 targetCollateralValue = totalUusdMinted.mul(WEI_VALUE).div(MIN_HEALTH_FACTOR);

        // Calculate the current excess collateral (collateral - targetCollateral)
        uint256 excessCollateral = collateralValueInUsd > targetCollateralValue ? collateralValueInUsd - targetCollateralValue : 0;

        if (excessCollateral > 0) {
            // Calculate the maximum amount of stable collateral that can be withdrawn
            maxStableWithdraw = excessCollateral.mul(1e18).div(stableColatPrice);

            // Calculate the maximum amount of unstable collateral that can be withdrawn
            maxUnstableWithdraw = excessCollateral.mul(1e18).div(unstableColPrice);
        }
    }




    // if the address exists in current investors list
    function existInInvestors(address investor) public view returns(bool) {
        for(uint256 j = 0; j < investors1.length; j ++) {
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