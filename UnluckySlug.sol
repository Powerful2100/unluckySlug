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
contract UnluckySlug is VRFConsumerBaseV2, ERC721, IERC721Receiver, Ownable, Pausable, ReentrancyGuard {
    // to Increment the tokenId of the goldenTicket
    using Counters for Counters.Counter;
    Counters.Counter private _tokenIds;
    uint256 LIMIT_GOLDEN_TICKETS = 10000;
    // Chainlink VRF v2 Variables
    VRFCoordinatorV2Interface COORDINATOR;
    address VRF_COORDINATOR = 0x271682DEB8C4E0901D1a1550aD2e64D568E69909;
    bytes32 keyHash = 0xff8dedfbfa60af186cf3c830acbc32c05aae823045ae5ea7da1e45fbfaba4f92;
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

    struct NFTs {
        address contractAddress;
        uint256 tokenID;
        uint256 weiCost;
        uint256 probability;
    }

    NFTs[] public topNFTs;
    NFTs[] public mediumNFTs;
    NFTs[] public normalNFTs;

    // @dev Helpers to calculate probability of each NFT
    uint256 public averageWeiCostTopNFTs;
    uint256 public sumWeiCostTopNFTs;
    uint256 public averageWeiCostMediumNFTs;
    uint256 public sumWeiCostMediumNFTs;
    uint256 public averageWeiCostNormalNFTs;
    uint256 public sumWeiCostNormalNFTs;

    uint256 public topGroupProbability;
    uint256 public mediumGroupProbability;
    uint256 public normalGroupProbability;
    uint256 public refundHundredTicketProbability;
    uint256 public refundTenTicketProbability;
    uint256 public refundOneTicketProbability;
    uint256 public noneGroupProbability;

    uint256[8] public groupCumValues;
    uint256[] public topNFTsCumValues;
    uint256[] public mediumNFTsCumValues;
    uint256[] public normalNFTsCumValues;

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
    uint256 public probabilityEquivalentToOne = 10000000;
    // @dev Probability of JackPot is 1/probabilityEquivalentToOne which is equivalent to 0.000001
    uint256 public jackPotProbability = 1;
    // @dev Probability of GoldenTicket initially is 19683/probabilityEquivalentToOne which is
    //      equivalent to 0.019683. Every 2000 mints, the probability is divided by 3... so the
    //      sequence of probabilities are 196830 -> 65610 -> 21870 -> 7290 -> 2430
    //      It takes approximately 15,000,000 throws to mint all of the collection
    uint256 public goldenTicketProbability = 196830;
    // @dev Percentage of the value of the ticket which go to the JackPot
    uint8 public valuePercentageToJackpot = 5;
    // @dev Percentage of the value of the ticket which go to the Referrer if the player has one
    uint8 public referrerCommisionPercentage = 2;
    // @dev Percentage value of the ticket which go to the player if the player has a referrer
    uint8 public cashbackIncentivePercentage = 2;
    event JackPot(address indexed _to, uint256 _value);
    event TicketRepayment(address indexed _to, uint256 _value);
    event DepositNFT(address contractAddress, uint256 tokenID, uint256 WeiCost);
    event WithdrawNFT(address indexed player, address contractAddress, uint256 tokenID);

    // @dev Constructor to set up the VRF Consumer
    // @param subscriptionId Identifier of the VRF Subscription
    constructor(uint64 _subscriptionID) VRFConsumerBaseV2(VRF_COORDINATOR) ERC721("UnluckySlug", "SLUG") {
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

    // @dev Function to withdraw all the NFTs deposited from the smart contract
    // @param _to Address to send the funds
    function withdrawAllNFTs(address _to) public onlyOwner {
        for (uint i=0; i<topNFTs.length; i++) {
            ERC721(topNFTs[i].contractAddress).safeTransferFrom(address(this), _to, topNFTs[i].tokenID);
        }
        for (uint i=0; i<mediumNFTs.length; i++) {
            ERC721(mediumNFTs[i].contractAddress).safeTransferFrom(address(this), _to, mediumNFTs[i].tokenID);
        }
        for (uint i=0; i<normalNFTs.length; i++) {
            ERC721(normalNFTs[i].contractAddress).safeTransferFrom(address(this), _to, normalNFTs[i].tokenID);
        }
        delete topNFTs;
        delete mediumNFTs;
        delete normalNFTs;
        delete averageWeiCostTopNFTs;
        delete sumWeiCostTopNFTs;
        delete averageWeiCostMediumNFTs;
        delete sumWeiCostMediumNFTs;
        delete averageWeiCostNormalNFTs;
        delete sumWeiCostNormalNFTs;
        delete topGroupProbability;
        delete mediumGroupProbability;
        delete normalGroupProbability;
        delete noneGroupProbability;
        delete groupCumValues;
        delete topNFTsCumValues;
        delete mediumNFTsCumValues;
        delete normalNFTsCumValues;
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

    // @dev Function for the owner to be able to deposit TOP NFTs. The estimated cost is 100ETH per NFT in this group.
    // @param contractAddress The contract address of the NFT to be deposited
    // @param tokenID The token ID of the NFT to be deposited
    // @param WeiCost Estimated cost of the NFT in Wei
    function depositTopNFT(address contractAddress, uint256 tokenID, uint256 WeiCost)
        public
        onlyOwner
    {
        ERC721 NFTContract = ERC721(contractAddress);
        NFTContract.safeTransferFrom(msg.sender, address(this), tokenID);
        topNFTs.push(NFTs(contractAddress, tokenID, WeiCost, 0));
        sumWeiCostTopNFTs += WeiCost;
        averageWeiCostTopNFTs = sumWeiCostTopNFTs / topNFTs.length;
        recalculateTopProbabilities();
        recalculateGroupProbabilities();
        recalulateCumGroupProb();
        emit DepositNFT(contractAddress, tokenID, WeiCost);
    }

    // @dev Function for the owner to be able to deposit MEDIUM NFTs. The estimated cost is 10ETH per NFT in this group.
    // @param contractAddress The contract address of the NFT to be deposited
    // @param tokenID The token ID of the NFT to be deposited
    // @param WeiCost Estimated cost of the NFT in Wei
    function depositMediumNFT(address contractAddress, uint256 tokenID, uint256 WeiCost)
        public
        onlyOwner
    {
        ERC721 NFTContract = ERC721(contractAddress);
        NFTContract.safeTransferFrom(msg.sender, address(this), tokenID);
        mediumNFTs.push(NFTs(contractAddress, tokenID, WeiCost, 0));
        sumWeiCostMediumNFTs += WeiCost;
        averageWeiCostMediumNFTs = sumWeiCostMediumNFTs / mediumNFTs.length;
        recalculateMediumProbabilities();
        recalculateGroupProbabilities();
        recalulateCumGroupProb();
        emit DepositNFT(contractAddress, tokenID, WeiCost);
    }

    // @dev Function for the owner to be able to deposit NORMAL NFTs. The estimated cost is 1ETH per NFT in this group.
    // @param contractAddress The contract address of the NFT to be deposited
    // @param tokenID The token ID of the NFT to be deposited
    // @param WeiCost Estimated cost of the NFT in Wei
    function depositNormalNFT(address contractAddress, uint256 tokenID, uint256 WeiCost)
        public
        onlyOwner
    {
        ERC721 NFTContract = ERC721(contractAddress);
        NFTContract.safeTransferFrom(msg.sender, address(this), tokenID);
        normalNFTs.push(NFTs(contractAddress, tokenID, WeiCost, 0));
        sumWeiCostNormalNFTs += WeiCost;
        averageWeiCostNormalNFTs = sumWeiCostNormalNFTs / normalNFTs.length;
        recalculateNormalProbabilities();
        recalculateGroupProbabilities();
        recalulateCumGroupProb();
        emit DepositNFT(contractAddress, tokenID, WeiCost);
    }

    // @dev Function to withdraw TOP NFTs. This function is internally called after receiving the random numbers
    //      from ChainLink VRF
    // @param index Index in the TopNFTs array to be withdrawn
    // @param requestId requestId generated by ChainLink VRF to identity different requests
    function withdrawTopNFT(uint256 index, address player) internal {
        NFTs memory NFTPrize = topNFTs[index];
        ERC721 NFTContract = ERC721(NFTPrize.contractAddress);
        NFTContract.safeTransferFrom(address(this), player, NFTPrize.tokenID);
        topNFTs[index] = topNFTs[topNFTs.length - 1];
        topNFTs.pop();
        sumWeiCostTopNFTs -= NFTPrize.weiCost;
        if (topNFTs.length == 0) {
            averageWeiCostTopNFTs = 0;
        } else {
            averageWeiCostTopNFTs = sumWeiCostTopNFTs / topNFTs.length;
            recalculateTopProbabilities();
        }
        recalculateGroupProbabilities();
        recalulateCumGroupProb();
        emit WithdrawNFT(player, NFTPrize.contractAddress, NFTPrize.tokenID);
    }

    // @dev Function to withdraw MEDIUM NFTs. This function is internally called after receiving the random numbers
    //      from ChainLink VRF
    // @param index Index in the TopNFTs array to be withdrawn
    // @param requestId requestId generated by ChainLink VRF to identity different requests
    function withdrawMediumNFT(uint256 index, address player) internal {
        NFTs memory NFTPrize = mediumNFTs[index];
        ERC721 NFTContract = ERC721(NFTPrize.contractAddress);
        NFTContract.safeTransferFrom(address(this), player, NFTPrize.tokenID);
        mediumNFTs[index] = mediumNFTs[mediumNFTs.length - 1];
        mediumNFTs.pop();
        sumWeiCostMediumNFTs -= NFTPrize.weiCost;
        if (mediumNFTs.length == 0) {
            averageWeiCostMediumNFTs = 0;
        } else {
            averageWeiCostMediumNFTs = sumWeiCostMediumNFTs / mediumNFTs.length;
            recalculateMediumProbabilities();
        }
        recalculateGroupProbabilities();
        recalulateCumGroupProb();
        emit WithdrawNFT(player, NFTPrize.contractAddress, NFTPrize.tokenID);
    }

    // @dev Function to withdraw NORMAL NFTs. This function is internally called after receiving the random numbers
    //      from ChainLink VRF
    // @param index Index in the TopNFTs array to be withdrawn
    // @param requestId requestId generated by ChainLink VRF to identity different requests
    function withdrawNormalNFT(uint256 index, address player) internal {
        NFTs memory NFTPrize = normalNFTs[index];
        ERC721 NFTContract = ERC721(NFTPrize.contractAddress);
        NFTContract.safeTransferFrom(address(this), player, NFTPrize.tokenID);
        normalNFTs[index] = normalNFTs[normalNFTs.length - 1];
        normalNFTs.pop();
        sumWeiCostNormalNFTs -= NFTPrize.weiCost;
        if (normalNFTs.length == 0) {
            averageWeiCostNormalNFTs = 0;
        } else {
            averageWeiCostNormalNFTs = sumWeiCostNormalNFTs / normalNFTs.length;
            recalculateNormalProbabilities();
        }
        recalculateGroupProbabilities();
        recalulateCumGroupProb();
        emit WithdrawNFT(player, NFTPrize.contractAddress, NFTPrize.tokenID);
    }

    // @dev Helper function to recalculate the probabilities of the different groups.
    //      Notice that noneGroupProbability is calculated from substracting the other probabilities, which is
    //      not a problem since the probabilities are very small.
    function recalculateGroupProbabilities() internal {
        if (averageWeiCostTopNFTs == 0) {
            topGroupProbability = 0;
        } else {
            topGroupProbability = ticketCost * probabilityEquivalentToOne / (averageWeiCostTopNFTs * constantProbability);
        }
        if (averageWeiCostMediumNFTs == 0) {
            mediumGroupProbability = 0;
        } else {
            mediumGroupProbability = ticketCost * probabilityEquivalentToOne / (averageWeiCostMediumNFTs * constantProbability);
        }
        if (averageWeiCostNormalNFTs == 0) {
            normalGroupProbability = 0;
        } else {
            normalGroupProbability = ticketCost * probabilityEquivalentToOne / (averageWeiCostNormalNFTs * constantProbability);
        }
        refundHundredTicketProbability = probabilityEquivalentToOne / (100 * constantProbability);
        refundTenTicketProbability = probabilityEquivalentToOne / (10 * constantProbability);
        refundOneTicketProbability = probabilityEquivalentToOne / constantProbability;
        noneGroupProbability = probabilityEquivalentToOne - (jackPotProbability + topGroupProbability + mediumGroupProbability +
             normalGroupProbability + refundHundredTicketProbability + refundTenTicketProbability + refundOneTicketProbability);
    }

    // @dev Helper function to recalculate the cumulative values of the different groups, which is very useful to determine
    //      if a player has won a prize.
    function recalulateCumGroupProb() internal {
        uint256[8] memory groupProbabilities = [
            jackPotProbability,
            topGroupProbability,
            mediumGroupProbability,
            normalGroupProbability,
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

    // @dev Helper function to normalize the TOP NFTs Probabilities based on their cost
    function recalculateTopProbabilities() internal {
        delete topNFTsCumValues;
        uint256 cumValue;
        for (uint i=0; i<topNFTs.length; i++) {
            topNFTs[i].probability = topNFTs[i].weiCost * probabilityEquivalentToOne / sumWeiCostTopNFTs;
            cumValue += topNFTs[i].probability;
            topNFTsCumValues.push(cumValue);
        }
    }

    // @dev Helper function to normalize the MEDIUM NFTs Probabilities based on their cost
    function recalculateMediumProbabilities() internal {
        delete mediumNFTsCumValues;
        uint256 cumValue;
        for (uint i=0; i<mediumNFTs.length; i++) {
            mediumNFTs[i].probability = mediumNFTs[i].weiCost * probabilityEquivalentToOne / sumWeiCostMediumNFTs;
            cumValue += mediumNFTs[i].probability;
            mediumNFTsCumValues.push(cumValue);
        }
    }

    // @dev Helper function to normalize the NORMAL NFTs Probabilities based on their cost
    function recalculateNormalProbabilities() internal {
        delete normalNFTsCumValues;
        uint256 cumValue;
        for (uint i=0; i<normalNFTs.length; i++) {
            normalNFTs[i].probability = normalNFTs[i].weiCost * probabilityEquivalentToOne / sumWeiCostNormalNFTs;
            cumValue += normalNFTs[i].probability;
            normalNFTsCumValues.push(cumValue);
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
        uint256 nftRandomRange = (randomWords[1] % probabilityEquivalentToOne) + 1;
        uint8 slugMultiplier = getSlugmeterMultiplier(player);
        if (groupRandomRange <= groupCumValues[0] * slugMultiplier){
            // JackPot Prize
            sendJackPot(player);
            unluckyThrows[player] = 0;
        } else if (groupRandomRange <= groupCumValues[1] * slugMultiplier) {
            // Top NFT Prize
            uint256 index = checkNFTPrize(nftRandomRange, 1);
            withdrawTopNFT(index, player);
            unluckyThrows[player] = 0;
        } else if (groupRandomRange <= groupCumValues[2] * slugMultiplier) {
            // Medium NFT Prize
            uint256 index = checkNFTPrize(nftRandomRange, 2);
            withdrawMediumNFT(index, player);
            unluckyThrows[player] = 0;
        } else if (groupRandomRange <= groupCumValues[3] * slugMultiplier) {
            // Normal NFT Prize
            uint256 index = checkNFTPrize(nftRandomRange, 3);
            withdrawNormalNFT(index, player);
            unluckyThrows[player] = 0;
        } else if (groupRandomRange <= groupCumValues[4] * slugMultiplier) {
            // Refund x100 Ticket Prize
            payable(player).transfer(100 * ticketCost);
            emit TicketRepayment(player, 100 * ticketCost);
            unluckyThrows[player] = 0;
        } else if (groupRandomRange <= groupCumValues[5] * slugMultiplier) {
            // Refund x10 Ticket Prize
            payable(player).transfer(10 * ticketCost);
            emit TicketRepayment(player, 10 * ticketCost);
            unluckyThrows[player] = 0;
        } else if (groupRandomRange <= groupCumValues[6] * slugMultiplier) {
            // Refund x1 Ticket Prize
            payable(player).transfer(ticketCost);
            emit TicketRepayment(player, ticketCost);
            unluckyThrows[player] = 0;
        } else {
            if (nftRandomRange <= goldenTicketProbability) {
                mintGoldenTicket(player);
            }
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

    // @dev Function to mint a GoldenTicket for the players who have not won any 'prize' but at least the bastards had a little bit of luck
    // @param player Address of the player
    function mintGoldenTicket(address player) internal {
        uint256 newItemId;
        _tokenIds.increment();
        newItemId = _tokenIds.current();
        if (newItemId <= LIMIT_GOLDEN_TICKETS) {
            _mint(player, newItemId);
            if (newItemId % 2000 == 0) {
                goldenTicketProbability /= 3;
            }
        }
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

    // @dev Function to get the index of the NFT to be sent from a group.
    // @param nftRandomRange Random Number which determines which of the NFT prize is
    // @param group Group to be calculated the index
    // @return index Index in the TopNFTs array to be withdrawn
    function checkNFTPrize(uint256 nftRandomRange, uint8 group) internal view returns (uint256) {
        uint256 index;
        uint256[] memory NFTarray;
        if (group == 1) {
            NFTarray = topNFTsCumValues;
        } else if (group == 2) {
            NFTarray = mediumNFTsCumValues;
        } else {
            NFTarray = normalNFTsCumValues;
        }
        if (nftRandomRange <= NFTarray[0]) {
            index = 0;
        } else if (nftRandomRange >= NFTarray[NFTarray.length - 1]) {
            index = NFTarray.length - 1;
        } else {
            for (uint i=0; i<NFTarray.length - 1; i++) {
                if (NFTarray[i] < nftRandomRange && nftRandomRange <= NFTarray[i+1]) {
                    index = i;
                }
            }
        }
        return index;
    }
}
