// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "../openzeppelin/utils/math/SafeMath.sol";
import "./EXNToken.sol";
import "./EXNStaking.sol";

contract EXNReferralSystem is Ownable {
    using SafeMath for uint256;

    event Register(address user, address referrer);
    event RankChange(address user, uint256 oldRank, uint256 newRank);
    event PayCommission(
        address sender,
        address recipient,
        uint256 amount,
        uint8 level
    );
    event ChangedCareerValue(address user, uint256 changeAmount, bool positive);
    event ReceiveRankReward(address user, uint256 caseReward);


    uint256 internal constant COMMISSION_RATE = 20 * (10**16); // 20%
    uint256 internal constant CASE_PRECISION = 10**8;
    uint256 public constant CASE_MINT_CAP = 264000000 * CASE_PRECISION;
    uint8 internal constant COMMISSION_LEVELS_MAX = 8;

    mapping(address => address) public referrerOf;
     mapping(address => uint256) public rewardInEXNUserRankTotal; 
    mapping(address => bool) public isUser;
    mapping(address => uint256) public careerValue;
    mapping(address => uint256) public rankOf;
    mapping(uint256 => mapping(uint256 => uint256)) public rankReward;
    mapping(address => mapping(uint256 => uint256)) public downlineRanks;

    uint256[] public commissionPercentages;
    uint256[] public commissionStakeRequirements;
    uint256 public mintedEXNTokens;

    EXNStaking public expStaking;
    EXNToken public expToken;
    mapping(address => address[]) public mapReferalList;
    mapping(address => uint256[]) public mapReferalListDate;

    modifier regUser(address user) {
        if (!isUser[user]) {
            isUser[user] = true;
            emit Register(user, address(0));
        }
        _;
    }

    constructor(
        address _expStaking,
        address _expToken
    ) {
        // initialize commission percentages for each level
        commissionPercentages.push(8 * (10**16)); // 8%
        commissionPercentages.push(5 * (10**16)); // 5%
        commissionPercentages.push(2.5 * (10**16)); // 2.5%
        commissionPercentages.push(1.5 * (10**16)); // 1.5%
        commissionPercentages.push(1 * (10**16)); // 1%
        commissionPercentages.push(1 * (10**16)); // 1%
        commissionPercentages.push(5 * (10**15)); // 0.5%
        commissionPercentages.push(5 * (10**15)); // 0.5%

        // initialize commission stake requirements for each level
        commissionStakeRequirements.push(0);
        commissionStakeRequirements.push(CASE_PRECISION.mul(5000));
        commissionStakeRequirements.push(CASE_PRECISION.mul(10000));
        commissionStakeRequirements.push(CASE_PRECISION.mul(15000));
        commissionStakeRequirements.push(CASE_PRECISION.mul(17500));
        commissionStakeRequirements.push(CASE_PRECISION.mul(20000));
        commissionStakeRequirements.push(CASE_PRECISION.mul(22500));
        commissionStakeRequirements.push(CASE_PRECISION.mul(25000));

        // initialize rank rewards
        for (uint256 i = 0; i < 8; i = i.add(1)) {
            uint256 rewardInEXN = 0;
            for (uint256 j = i.add(1); j <= 8; j = j.add(1)) {
                if (j == 1) {
                    rewardInEXN = rewardInEXN.add(CASE_PRECISION.mul(1000));
                } else if (j == 2) {
                    rewardInEXN = rewardInEXN.add(CASE_PRECISION.mul(2000));
                } else if (j == 3) {
                    rewardInEXN = rewardInEXN.add(CASE_PRECISION.mul(5000));
                } else if (j == 4) {
                    rewardInEXN = rewardInEXN.add(CASE_PRECISION.mul(15000));
                } else if (j == 5) {
                    rewardInEXN = rewardInEXN.add(CASE_PRECISION.mul(50000));
                } else if (j == 6) {
                    rewardInEXN = rewardInEXN.add(CASE_PRECISION.mul(100000));
                } else if (j == 7) {
                    rewardInEXN = rewardInEXN.add(CASE_PRECISION.mul(250000));
                } else {
                    rewardInEXN = rewardInEXN.add(CASE_PRECISION.mul(500000));
                }
                rankReward[i][j] = rewardInEXN;
            }
        }

        expStaking = EXNStaking(_expStaking);
        expToken = EXNToken(_expToken);
        _transferOwnership(_expStaking);
    }


    function multiRefer(address[] calldata users, address[] calldata referrers) external onlyOwner {
        require( users.length == referrers.length, "EXNReward: arrays length are not equal" );
        for (uint256 i = 0; i < users.length; i++) {
            refer(users[i], referrers[i]);
        }
    }

    function refer(address user, address referrer) public onlyOwner {
        require(!isUser[user], "EXNReward: referred is already a user");
        require(user != referrer, "EXNReward: can't refer self");
        require( user != address(0) && referrer != address(0), "EXNReward: 0x address");

        isUser[user] = true;
        isUser[referrer] = true;

        referrerOf[user] = referrer;
        downlineRanks[referrer][0] = downlineRanks[referrer][0].add(1);
        
        mapReferalList[referrer].push(user);
        mapReferalListDate[referrer].push(block.timestamp);
        emit Register(user, referrer);
    }

    function getDownlineRanks(address user, uint256 index) public view returns (uint256) {
       return downlineRanks[user][index];
    }

    function canRefer(address user, address referrer)  public view returns (bool) {
        return !isUser[user] &&
            user != referrer &&
            user != address(0) &&
            referrer != address(0);
    }

    function getMapReferalList(address referrer) public view returns (address[] memory) {
        return mapReferalList[referrer];
    }

    function getMapReferalListDate(address referrer) public view returns (uint256[] memory) {
        return mapReferalListDate[referrer];
    }

    function payCommission(  address referrer, address sender, uint256 rawCommission) public regUser(referrer) onlyOwner returns (uint256 leftoverAmount) {
        address ptr = referrer;
        uint256 commissionLeft = rawCommission;
        uint8 i = 0;
        while (ptr != address(0) && i < COMMISSION_LEVELS_MAX) {
            if (_expStakeOf(ptr) >= commissionStakeRequirements[i]) {
                uint256 commission = rawCommission.mul(commissionPercentages[i]).div(COMMISSION_RATE);

                if (commission > commissionLeft) {
                    commission = commissionLeft;
                }
                expToken.mint(ptr, commission);
                commissionLeft = commissionLeft.sub(commission);

                incrementCareerValueInEXN(ptr, commission.div(100));
                emit PayCommission(sender, ptr, commission, i);
            }

            ptr = referrerOf[ptr];
            i += 1;
        }
        return commissionLeft;
    }


    function incrementCareerValueInEXN(address user, uint256 incCVInEXN) public regUser(user) onlyOwner {
        careerValue[user] = careerValue[user].add(incCVInEXN);
        emit ChangedCareerValue(user, incCVInEXN, true);
    }

    function cvRankOf(address user) public view returns (uint256) {
        uint256 cv = careerValue[user];
        if (cv < CASE_PRECISION.mul(100)) {
            return 0;
        } else if (cv < CASE_PRECISION.mul(200)) {
            return 1;
        } else if (cv < CASE_PRECISION.mul(500)) {
            return 2;
        } else if (cv < CASE_PRECISION.mul(1500)) {
            return 3;
        } else if (cv < CASE_PRECISION.mul(5000)) {
            return 4;
        } else if (cv < CASE_PRECISION.mul(10000)) {
            return 5;
        } else if (cv < CASE_PRECISION.mul(50000)) {
            return 6;
        } else if (cv < CASE_PRECISION.mul(150000)) {
            return 7;
        } else {
            return 8;
        }
    }

    function rankUp(address user) external {
        // verify rank up conditions
        uint256 currentRank = rankOf[user];
        uint256 cvRank = cvRankOf(user);
        require(
            cvRank > currentRank,
            "EXNReward: career value is not enough!"
        );
        require(
            downlineRanks[user][currentRank] >= 2 || currentRank == 0,
            "EXNReward: downlines count and requirement not passed!"
        );

        uint256 targetRank = currentRank + 1;

        rankOf[user] = targetRank;
        emit RankChange(user, currentRank, targetRank);

        address referrer = referrerOf[user];
        if (referrer != address(0)) {
            downlineRanks[referrer][targetRank] = downlineRanks[referrer][targetRank].add(1);
        }

        uint256 rewardInEXN = rankReward[currentRank][targetRank];

        uint256 mintedEXNTokens_CHECK = mintedEXNTokens.add(rewardInEXN);
        require( mintedEXNTokens <= CASE_MINT_CAP , "EXNReward: EXN limit exceeded");
        mintedEXNTokens = mintedEXNTokens_CHECK;
        expToken.mint(user, rewardInEXN); 

        rewardInEXNUserRankTotal[user] = rewardInEXNUserRankTotal[user].add(rewardInEXN);
        emit ReceiveRankReward(user, rewardInEXN);
    }

    function canRankUp(address user) external view returns (bool) {
        uint256 currentRank = rankOf[user];
        uint256 cvRank = cvRankOf(user);
        return  (cvRank > currentRank) && (downlineRanks[user][currentRank] >= 2 || currentRank == 0);
    }


    function _expStakeOf(address user) internal view returns (uint256) {
        return expStaking.userStakeAmount(user);
    }
}
