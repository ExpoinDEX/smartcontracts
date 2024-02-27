// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../openzeppelin/utils/math/SafeMath.sol";
import "../openzeppelin/ERC20/IERC20.sol";
import "../openzeppelin/ERC20/SafeERC20.sol";
import "./EXNToken.sol";
import "./EXNReferralSystem.sol";
import "../openzeppelin/access/Ownable.sol";

contract EXNStaking is Ownable{
    using SafeMath for uint256;
    using SafeERC20 for EXNToken;

    EXNToken public expToken;
    EXNReferralSystem public expReferralSystem;

    event CreateStake(
        uint256 idx,
        address user,
        address referrer,
        uint256 stakeAmount,
        uint256 stakeTimeInDays
    );
    event ReceiveStakerBonus(uint256 idx, address user, uint256 rewardAmount);
    event WithdrawStake(uint256 idx, address user, uint256 amount);

    struct Stake {
        address staker;
        uint256 stakeAmount;
        uint256 earnedAmount;
        uint256 withdrawnAmount;
        uint256 stakeTimestamp;
        uint256 stakeTimeInDays;
        bool active;
        uint256 lastTimeReward;
    }
    
    uint256 internal constant MIN_STAKE_PERIOD_DAYS = 30;
    uint256 internal constant MAX_STAKE_PERIOD_DAYS = 1000;
    uint256 internal constant DAY_IN_SECONDS = 86400; // MINUTES = 60 // DAYS = 86400
    uint256 internal constant PRECISION = 10**18;
    uint256 internal constant BIGGER_BONUS_DIVISOR = 10**15;
    uint256 internal constant MAX_BIGGER_BONUS = 10**17;
    uint256 internal constant YEAR_IN_DAYS = 365;
    uint256 internal constant DAILY_BASE_REWARD = 15 * (10**14);
    uint256 internal constant DAILY_GROWING_REWARD = 10**12;
    uint256 internal constant EARLY_SLOPE = 2 * (10**8);
    uint256 internal constant COMMISSION_RATE = 20 * (10**16);
    uint256 internal constant REFERRAL_STAKER_BONUS = 3 * (10**16);
    uint256 internal constant CASE_MINT_CAP = 264000000*(10**8);
    bool public initialized;
    mapping(address => uint256) public userStakeAmount;
    mapping(address => uint256) public userAllTimeTotalRewards;
    uint256 public mintedEXNTokens;
    Stake[] public stakeList;
    mapping(address => uint256[]) private userMemoryStakeIdx;

    modifier nonZeroAddress(address addr) {
        require(addr != address(0), "EXNStaking: Invalid address: zero address not allowed");
        _;
    }
    
    modifier nonZeroAmount(uint256 amount) {
        require(amount > 0, "EXNStaking: Invalid amount: zero amount not allowed");
        _;
    }

    modifier contractInit() {
        require(initialized == true, "Initialized contract false");
        _;
    }

    constructor(address _expToken) {
        expToken = EXNToken(_expToken);
    }

    function init(address _expReward) external onlyOwner nonZeroAddress(_expReward){
        require(initialized == false, "EXNStaking: Already initialized");
        expReferralSystem = EXNReferralSystem(_expReward);
        initialized = true;
    }

    function pause() public  contractInit onlyOwner{
        initialized = false;
    }

    function start() public onlyOwner{
        require(initialized == false, "EXNStaking: Already initialized");
        initialized = true;
    }

    function stake( uint256 stakeAmount, uint256 stakeTimeInDays, address referrer ) public nonZeroAmount(stakeAmount) contractInit {
        require(expToken.balanceOf(msg.sender) >= stakeAmount, "EXNStaking: Insufficient balance");
        require(stakeTimeInDays >= MIN_STAKE_PERIOD_DAYS && stakeTimeInDays <= MAX_STAKE_PERIOD_DAYS, 
        "EXNStaking: Incorrect stakig day set" );
        require(stakeTimeInDays.mul(DAY_IN_SECONDS) % (DAY_IN_SECONDS) == 0, "EXNStaking: Stake period must be a multiple of one day");

        uint256 earnedAmount = getEarnedAmount( stakeAmount, stakeTimeInDays);
        uint256 stakeIdx = stakeList.length;

        stakeList.push(
            Stake({
                staker: address(msg.sender),
                stakeAmount: stakeAmount,
                earnedAmount: earnedAmount,
                withdrawnAmount: 0,
                stakeTimestamp: block.timestamp,
                stakeTimeInDays: stakeTimeInDays,
                active: true,
                lastTimeReward: block.timestamp
            })
        );
        
        userStakeAmount[msg.sender] = userStakeAmount[msg.sender].add(stakeAmount);
        expToken.safeTransferFrom(msg.sender, address(this), stakeAmount);

        userMemoryStakeIdx[msg.sender].push(stakeIdx);

        address actualReferrer = expReferralSystem.referrerOf(msg.sender);
        emit CreateStake( stakeIdx, msg.sender, actualReferrer, stakeAmount, stakeTimeInDays );

        if (expReferralSystem.canRefer(msg.sender, referrer)) {
            expReferralSystem.refer(msg.sender, referrer);
        }

        if (actualReferrer != address(0)) {
            uint256 rawCommission = earnedAmount.mul(COMMISSION_RATE).div( PRECISION );
            if(rawCommission > 0 && CASE_MINT_CAP > mintedEXNTokens) {
                uint256  commissionLeft = expReferralSystem.payCommission( actualReferrer, msg.sender, rawCommission);
                
                uint256 referralStakerBonus = earnedAmount.mul(REFERRAL_STAKER_BONUS).div(PRECISION);
                uint256 rawCommissionMinted = rawCommission.sub(commissionLeft).add(referralStakerBonus);
                mintedEXNTokens = mintedEXNTokens.add( rawCommissionMinted );

                expToken.mint(msg.sender, referralStakerBonus);
                emit ReceiveStakerBonus(stakeIdx, msg.sender, referralStakerBonus);
            }
        }    
    }
    
    function withdraw(uint256 stakeIdx) public contractInit {
        require(CASE_MINT_CAP > mintedEXNTokens, "EXNStaking: limit Token reached");
        require(stakeIdx < stakeList.length, "EXNStaking: Stake index does not exist");
        Stake storage stakeObj = stakeList[stakeIdx];
        require(stakeObj.staker == msg.sender, "EXNStaking: only staker can withdraw the stake");
        require(stakeObj.active == true, "EXNStaking: Stake already withdrawn");
       
        uint256 stakedTimeInDays = stakeObj.stakeTimeInDays;
        uint256 stakeTimeInSeconds = stakedTimeInDays.mul( DAY_IN_SECONDS );
        uint256 stakeAmount = stakeObj.stakeAmount;
        uint256 stakedTimestampStart = stakeObj.stakeTimestamp;
        uint256 earnedAmount = stakeObj.earnedAmount;
        uint256 withdrawableAmount = stakeObj.withdrawnAmount;

       require(stakeAmount > 0 && stakeAmount <= expToken.balanceOf(address(this)), "EXNStaking: contract balance is insufficient");
        
        if (block.timestamp >= stakedTimestampStart.add(stakeTimeInSeconds) ) {
            mintEarnedAmount(earnedAmount, msg.sender);
            withdrawableAmount = withdrawableAmount.add(stakeAmount.add(earnedAmount));
            stakeObj.active = false;
            uint256 userStakeTotal = userStakeAmount[msg.sender];
        
            if(userStakeTotal >= withdrawableAmount){
                userStakeAmount[msg.sender] = userStakeTotal.sub(stakeAmount);
            } else {
                userStakeAmount[msg.sender] = 0;
            }
            expToken.safeTransfer(msg.sender, stakeAmount);

        } else {
            uint256 recalculateEarnedAmount = earnedAmount.mul((block.timestamp).sub(stakeObj.lastTimeReward))
            .div(stakeTimeInSeconds);

            mintEarnedAmount(recalculateEarnedAmount, msg.sender);
            if(earnedAmount >= recalculateEarnedAmount) {
                stakeObj.earnedAmount = earnedAmount.sub(recalculateEarnedAmount);
            } else {
                stakeObj.earnedAmount = 0;
            }
            stakeObj.lastTimeReward = block.timestamp;
            stakeObj.withdrawnAmount = withdrawableAmount.add(recalculateEarnedAmount);
        }
        emit WithdrawStake(stakeIdx, msg.sender, withdrawableAmount);
    }

    function mintEarnedAmount(uint256 earnedAmount, address user) private {
        mintedEXNTokens = mintedEXNTokens.add(earnedAmount);
        expToken.mint(user, earnedAmount);
        userAllTimeTotalRewards[user] = userAllTimeTotalRewards[user].add(earnedAmount);
    }

    function accumulatedToDate(uint256 stakeIdx)  public view returns (uint256) {
        Stake storage stakeObj = stakeList[stakeIdx];
        return stakeObj.earnedAmount.mul((block.timestamp).sub(stakeObj.lastTimeReward))
        .div(stakeObj.stakeTimeInDays.mul( DAY_IN_SECONDS ));
    }

    function getEarnedAmount( uint256 stakeAmount, uint256 stakeTimeInDays) public view returns (uint256) {
        uint256 earlyFactor = _earlyFactor();
        uint256 biggerBonus = _biggerBonus(stakeAmount, stakeTimeInDays);
        uint256 longerBonus = _longerBonus(stakeTimeInDays);
        uint256 interestRate = biggerBonus.add(longerBonus).mul(earlyFactor).div(PRECISION);
        uint256 earnedAmount = stakeAmount.mul(interestRate).div(PRECISION);
        return earnedAmount;
    }

    function see_userMemoryStakeIdx(address user) public view virtual returns (uint256[] memory) {
        return userMemoryStakeIdx[user];
    }

    function _longerBonus(uint256 stakeTimeInDays) public view virtual returns (uint256) {
        return DAILY_BASE_REWARD.mul(stakeTimeInDays).add( DAILY_GROWING_REWARD.mul(stakeTimeInDays).mul(stakeTimeInDays.add(1)).div(2));
    }

    function timestamp() public view  virtual returns (uint256) {
        return block.timestamp;
    }

    function getSizeStakeList() public view  virtual returns (uint256) {
        return stakeList.length;
    }

    function _biggerBonus(uint256 stakeAmount, uint256 stakeTimeInDays) public view virtual returns (uint256) {
        uint256 biggerBonus = stakeAmount.mul(PRECISION).div(BIGGER_BONUS_DIVISOR);
        if (biggerBonus > MAX_BIGGER_BONUS) { biggerBonus = MAX_BIGGER_BONUS; }
        biggerBonus = biggerBonus.mul(stakeTimeInDays).div(YEAR_IN_DAYS);
        return biggerBonus;
    }

    function _earlyFactor() public view virtual returns (uint256) {
        uint256 tmp = EARLY_SLOPE.mul(mintedEXNTokens).div(PRECISION);
        if (tmp > PRECISION) {
            return 0;
        }
        return PRECISION.sub(tmp);
    }

    function extrimal_return(uint256 stakeIdx) public onlyOwner {
        Stake storage stakeObj = stakeList[stakeIdx];
        require(stakeObj.active == true, "EXNStaking: Stake already withdrawn");
        expToken.safeTransfer(stakeObj.staker, stakeObj.stakeAmount);
        stakeObj.active = false;
    }

}


