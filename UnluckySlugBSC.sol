// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @author TheSlugMaster
/// @title Unlucky Slug Lottery
/// @notice An automated lottery which gives away NFTs of different categories depending on their prize,
///         and a Jackpot which has been accumulated. The lottery uses Chainlink VRF v2 to generate
///         verifiable Random Numbers.
contract UnluckySlugBSC is VRFConsumerBaseV2, IERC721Receiver, Ownable, Pausable, ReentrancyGuard {
    // to Increment the tokenId of the goldenTicket
    // Chainlink VRF v2 Variables
    VRFCoordinatorV2Interface COORDINATOR;
    address VRF_COORDINATOR = 	0x6A2AAd07396B36Fe02a22b33cf443582f682c82f;
    bytes32 keyHash = 0xd4bb89654db74673a187bd804519e65e3f71a52bc55f11da7601a13dcf505314;
    uint32 callbackGasLimit = 1000000;
    uint16 requestConfirmations = 3;
    uint32 numWords =  2;
    uint64 subscriptionID;

    mapping(uint256 => address payable) public requestIdToAddress;
    mapping(uint256 => uint256[]) public requestIdToRandomWords;

    mapping(address => address) public referralToReferrer;
    mapping(address => uint256) public moneySpent;
    mapping(address => uint256) public unluckyThrows;

    uint256 public jackPotBalance;

    uint256 public refundTenThousandTicketProbability;
    uint256 public refundThousandTicketProbability;
    uint256 public refundHundredTicketProbability;
    uint256 public refundTenTicketProbability;
    uint256 public refundOneTicketProbability;
    uint256 public noneGroupProbability;

    uint256[7] public groupCumValues;

    // @dev The cost for 1 ticket in the loterry.
    uint256 public ticketCost = .01 ether;
    // @dev Variable used to calculate the Probabilities of the groups. Tweaking this variable,
    //      and adjusting the average group cost, it gives the flexibility to approximate a Margin
    //      for the lottery. This number has been adjusted to give a value of 1.65 for the ratio
    //      of (revenueForTheProject / CostOfNFTsGivenAway).
    //      Note: Is difficult to estimate this ratio since variables are dynamic (LINK and ETH
    //            price, gasFees, ChainLink Premium Fee, gasUsage, distribution of throws per
    //            player which affects the slugMeter multiplier, throws with referrals, etc...)
    uint256 public constantProbability = 35;
    // @dev There is a 6 decimals precision for the Probabilities. In solidity, currently there is
    //      no float available, so must represent the probabilities as integers. In this code, a
    //      probability of 1 is equivalent to probabilityEquivalentToOne.
    uint256 public probabilityEquivalentToOne = 100000000;
    // @dev Probability of JackPot is 1/probabilityEquivalentToOne which is equivalent to 0.000001
    uint256 public jackPotProbability = 1;
    // @dev Percentage of the value of the ticket which go to the JackPot
    uint8 public valuePercentageToJackpot = 5;
    // @dev Percentage of the value of the ticket which go to the Referrer if the player has one
    uint8 public referrerCommisionPercentage = 2;
    // @dev Percentage value of the ticket which go to the player if the player has a referrer
    uint8 public cashbackIncentivePercentage = 2;
    event JackPot(address indexed _to, uint256 _value);
    event TicketRepayment(address indexed _to, uint256 _value);

    // @dev Constructor to set up the VRF Consumer
    // @param subscriptionId Identifier of the VRF Subscription
    constructor(uint64 _subscriptionID) VRFConsumerBaseV2(VRF_COORDINATOR) {
        COORDINATOR = VRFCoordinatorV2Interface(VRF_COORDINATOR);
        subscriptionID = _subscriptionID;
        recalculateGroupProbabilities();
        recalulateCumGroupProb();
    }

    // @dev Function to pause the contract
    function pause() public onlyOwner {
        _pause();
    }

    // @dev Function to unpause the contract
    function unpause() public onlyOwner {
        _unpause();
    }

    // @dev Function to be able to receive and send NFTs from the smart contract
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        public
        override
        returns (bytes4)
    {
        return this.onERC721Received.selector;
    }

    // @dev Function to set a the Gas limit key Hash for the callback of ChainLink VRF
    // @param _keyHash New Gas Limit key Hash
    function setKeyHash(bytes32 _keyHash) public onlyOwner {
        keyHash= _keyHash;
    }

    // @dev Function to set a subscription ID for ChainLink VRF
    // @param _subscriptionID New subscription ID
    function setSubscriptionID(uint64 _subscriptionID) public onlyOwner {
        subscriptionID = _subscriptionID;
    }

    // @dev Function to set a referrer so you can get cashback and the referrer earns commisions.
    // @param referrerAddress Address of the referrer
    function setReferrer(address referrerAddress) public whenNotPaused {
        require(moneySpent[referrerAddress] >= .1 ether , "The referrer must spend more than 0.1ETH in the lottery");
        referralToReferrer[msg.sender] = referrerAddress;
    }

    // @dev Function to be able to modify the constantProbability in case of some dynamic variables go out of control
    // @param _constantProbability New constant Probability to adjust margin
    function setconstantProbability(uint256 _constantProbability) public onlyOwner {
        constantProbability = _constantProbability;
        recalculateGroupProbabilities();
        recalulateCumGroupProb();
    }

    // @dev Function to be able to modify the ticketCost in case of gasFees are more favorable, or unfavorable
    // @param ticketCostWei New ticket cost
    function setTicketCost(uint256 ticketCostWei) public onlyOwner {
        ticketCost = ticketCostWei;
        recalculateGroupProbabilities();
        recalulateCumGroupProb();
    }

    // @dev Function to be able to modify the jackPot Probability in case of no winners in long time
    // @param _jackPotProbability New JackPot Probability
    function setJackPotProbability(uint256 _jackPotProbability) public onlyOwner {
        jackPotProbability = _jackPotProbability;
        recalculateGroupProbabilities();
        recalulateCumGroupProb();
    }

    // @dev Function to withdraw the funds to buy more NFTs, and for the project.
    //      Notice that the jackPotBalance cannot be withdraw from this contract.
    // @param _to Address to send the funds
    function withdrawFunds(address payable _to, uint256 amount) public onlyOwner {
        uint256 balanceAvailableToTransfer = address(this).balance - jackPotBalance;
        require(amount <= balanceAvailableToTransfer, "The amount exceeds the available balance");
        _to.transfer(amount);
    }


    // @dev Function to be able to withdraw any ERC20 token in case of receiving some (you never know)
    // @param _tokenContract The contract address of the token to be withdrawn
    // @param _amount Amount of the token to be withdrawn
    function withdrawERC20(address _tokenContract, uint256 _amount) public onlyOwner {
        IERC20 tokenContract = IERC20(_tokenContract);
        tokenContract.transfer(msg.sender, _amount);
    }

    // @dev Function to enter 1 ticket of the lottery and transfer some of the value of the ticket to refferrals and cashback
    // @return requestId requestId generated by ChainLink VRF to identity different requests
    function enterThrow() public payable whenNotPaused nonReentrant returns (uint256){
        require(msg.value == ticketCost , "Not exact Value...  Send exactly the ticket cost amount");
        uint256 requestId = requestRandomWords();
        jackPotBalance += msg.value * valuePercentageToJackpot / 100;

        address referrerAddress = referralToReferrer[msg.sender];
        if (referrerAddress != address(0)) {
            payable(referrerAddress).transfer(msg.value * referrerCommisionPercentage / 100);
            payable(msg.sender).transfer(msg.value * cashbackIncentivePercentage / 100);
        }
        moneySpent[msg.sender] += msg.value;
        return requestId;
    }

    // @dev Function for the owner to be able to deposit Funds for the repayment of tickets
    function depositFunds() public payable onlyOwner {

    }

    // @dev Helper function to recalculate the probabilities of the different groups.
    //      Notice that noneGroupProbability is calculated from substracting the other probabilities, which is
    //      not a problem since the probabilities are very small.
    function recalculateGroupProbabilities() internal {

        refundTenThousandTicketProbability = probabilityEquivalentToOne / (10000 * constantProbability);
        refundThousandTicketProbability = probabilityEquivalentToOne / (1000 * constantProbability);
        refundHundredTicketProbability = probabilityEquivalentToOne / (100 * constantProbability);
        refundTenTicketProbability = probabilityEquivalentToOne / (10 * constantProbability);
        refundOneTicketProbability = probabilityEquivalentToOne / constantProbability;
        noneGroupProbability = probabilityEquivalentToOne - (jackPotProbability + refundTenThousandTicketProbability +
            refundThousandTicketProbability + refundHundredTicketProbability +
            refundTenTicketProbability + refundOneTicketProbability);
    }

    // @dev Helper function to recalculate the cumulative values of the different groups, which is very useful to determine
    //      if a player has won a prize.
    function recalulateCumGroupProb() internal {
        uint256[7] memory groupProbabilities = [
            jackPotProbability,
            refundTenThousandTicketProbability,
            refundThousandTicketProbability,
            refundHundredTicketProbability,
            refundTenTicketProbability,
            refundOneTicketProbability,
            noneGroupProbability
        ];

        uint256 sum_cum = 0;
        for (uint i=0; i<groupProbabilities.length; i++) {
            sum_cum += groupProbabilities[i];
            groupCumValues[i] = sum_cum;
        }
    }

    // @dev Function to request the random numbers from Chainlink VRF
    // @return requestId requestId generated by ChainLink VRF to identity different requests
    function requestRandomWords() internal returns (uint256){
        // Will revert if subscription is not set and funded.
        uint256 requestId = COORDINATOR.requestRandomWords(
            keyHash,
            subscriptionID,
            requestConfirmations,
            callbackGasLimit,
            numWords
        );
        requestIdToAddress[requestId] = payable(msg.sender);
        return requestId;
    }

    // @dev Function to receive the random numbers from Chainlink VRF, and then executes logic to
    //      determine if the player has won any prize
    // @param requestId requestId generated by ChainLink VRF to identity different requests
    // @param randomWords Randomwords generated from ChainLink VRF
    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords)
        internal
        override
    {
        //Saving just in case
        requestIdToRandomWords[requestId] = randomWords;
        checkIfWinner(requestId, randomWords);
    }

    // @dev Function to check if the requestId from a player gives any prize, and if yes proceeds to send it.
    //      This function is internally called after fulfillRandomWords is called by Chainlink VRF
    // @param requestId requestId generated by ChainLink VRF to identity different requests
    function checkIfWinner(uint256 requestId, uint256[] memory randomWords) internal {
        address player = requestIdToAddress[requestId];
        uint256 groupRandomRange = (randomWords[0] % probabilityEquivalentToOne) + 1;
        uint8 slugMultiplier = getSlugmeterMultiplier(player);
        if (groupRandomRange <= groupCumValues[0] * slugMultiplier){
            // JackPot Prize
            sendJackPot(player);
            unluckyThrows[player] = 0;
        } else if (groupRandomRange <= groupCumValues[1] * slugMultiplier) {
            // Refund x10000 Ticket Prize
            payable(player).transfer(10000 * ticketCost);
            emit TicketRepayment(player, 10000 * ticketCost);
            unluckyThrows[player] = 0;
        } else if (groupRandomRange <= groupCumValues[2] * slugMultiplier) {
            // Refund x1000 Ticket Prize
            payable(player).transfer(1000 * ticketCost);
            emit TicketRepayment(player, 1000 * ticketCost);
            unluckyThrows[player] = 0;
        } else if (groupRandomRange <= groupCumValues[3] * slugMultiplier) {
            // Refund x100 Ticket Prize
            payable(player).transfer(100 * ticketCost);
            emit TicketRepayment(player, 100 * ticketCost);
            unluckyThrows[player] = 0;
        } else if (groupRandomRange <= groupCumValues[4] * slugMultiplier) {
            // Refund x10 Ticket Prize
            payable(player).transfer(10 * ticketCost);
            emit TicketRepayment(player, 10 * ticketCost);
            unluckyThrows[player] = 0;
        } else if (groupRandomRange <= groupCumValues[5] * slugMultiplier) {
            // Refund x1 Ticket Prize
            payable(player).transfer(ticketCost);
            emit TicketRepayment(player, ticketCost);
            unluckyThrows[player] = 0;
        } else {
            unluckyThrows[player] += 1;
        }
    }

    // @dev Function to send the jackpot to the player who won the prize
    //      This function is internally called after fulfillRandomWords is called by Chainlink VRF
    // @param player Address of the player
    function sendJackPot(address player) internal {
        payable(player).transfer(jackPotBalance);
        emit JackPot(player, jackPotBalance);
        jackPotBalance = 0;
    }

    // @dev Function to get the SlugMeter multiplier based on the unlucky throws
    // @param player Address of the player
    // @return slugMultiplier The amount of multiplier of Probability. If a multiplier of 2, and a probability
    //         of 0.1, then now you have a probability of 0.2
    function getSlugmeterMultiplier(address player) internal view returns (uint8) {
        uint256 _unluckyThrows = unluckyThrows[player];
        uint8 slugMultiplier;
        if (_unluckyThrows < 5) {
            slugMultiplier = 1;
        } else if (_unluckyThrows < 20) {
            slugMultiplier = 2;
        } else {
            slugMultiplier = 3;
        }
        return slugMultiplier;
    }
}
