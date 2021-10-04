//contracts/wallet/PerformanceDistribution.sol
// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;
pragma abicoder v2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

contract PerformanceDistribution is Ownable, ReentrancyGuard {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  struct DistributionInfo {
    uint256 amount; // for display list
    uint256 remainingAmount;
    uint256 rewardPerPeriod;
    uint256 lastUpdateBlock;
  }

  IERC20 public token;
  uint256 public blockPerDay; // BSC 28800, ETH 6500
  uint256 public distributionPeriod; // monthly(12), daily(365)
  uint256 public distributionFrequency; // monthly(30), daily(1)
  uint256 public blockPerPeriod;
  uint256 public distributionCap; // total amount to distribute
  uint256 public distributionBalance; // avaliable amount to add reward
  uint256 public distributed; // total distributed amount
  uint256 public nextDistributionBlock;
  uint256 public gracePeriodBlock;

  mapping(address => DistributionInfo[]) public distributionInfo;
  address[] private members;

  event LogAddReward(address indexed member, uint256 amount, uint256 rewardPerPeriod, uint256 lastUpdateBlock);
  event LogRemoveMember(address indexed member, uint256 remainingAmount);
  event LogDistributeReward(address indexed member, uint256 amount, uint256 remainingAmount);

  constructor(
    IERC20 _token,
    uint256 _distributionCap,
    uint256 _blockPerDay,
    uint256 _distributionFrequency,
    uint256 _distributionPeriod,
    uint256 _nextDistributionBlock,
    uint256 _gracePeriod // days
  ) {
    token = _token;
    distributionCap = _distributionCap;
    distributionBalance = _distributionCap;
    blockPerDay = _blockPerDay;
    blockPerPeriod = _blockPerDay.mul(_distributionFrequency);
    distributionFrequency = _distributionFrequency;
    distributionPeriod = _distributionPeriod;
    nextDistributionBlock = _nextDistributionBlock;
    gracePeriodBlock = _nextDistributionBlock.add(blockPerPeriod.mul(_distributionPeriod)).add(_blockPerDay.mul(_gracePeriod));
  }

  function memberLength() external view returns (uint256) {
    return members.length;
  }

  function addReward(
    address _for,
    uint256 amount,
    uint256 lastUpdateBlock
  ) external nonReentrant onlyOwner {
    require(token.balanceOf(address(this)) >= amount, "addReward:: exceed balance");
    require(distributionBalance >= amount, "addReward:: exceed balance");
    require(_for != address(0), "addReward: invalid address");

    uint256 minimumLastUpdateBlock = block.number.sub(blockPerPeriod);
    uint256 maximumLastUpdateBlock = block.number.add(blockPerPeriod);
    require(lastUpdateBlock >= minimumLastUpdateBlock, "addReward: exceed min lastUpdateBlock");
    require(lastUpdateBlock <= maximumLastUpdateBlock, "addReward: exceed max lastUpdateBlock");

    uint256 rewardPerPeriod = amount.div(distributionPeriod);

    if (distributionInfo[_for].length == 0) {
      members.push(_for);
    }

    distributionInfo[_for].push(
      DistributionInfo({
        amount: amount,
        remainingAmount: amount,
        rewardPerPeriod: rewardPerPeriod,
        lastUpdateBlock: lastUpdateBlock
      })
    );

    distributionBalance = distributionBalance.sub(amount);

    emit LogAddReward(_for, amount, rewardPerPeriod, lastUpdateBlock);
  }

  function distributeReward() external nonReentrant {
    require(
      block.number >= nextDistributionBlock,
      "distributeReward: unable to claim token due to it is in a lock period"
    );

    // get remaining period
    uint256 periodTimes = _getPeriodTimes(nextDistributionBlock);
    require(
      periodTimes > 0,
      "distributeReward: unable to claim token due to it is not reach its distribution timeframe"
    );

    // update block before next period distribution
    nextDistributionBlock = nextDistributionBlock.add(blockPerPeriod.mul(periodTimes));

    // distribute by one period * remaining period (times)
    for (uint256 i = 0; i < members.length; i++) {
      _distributeReward(members[i]);
    }
  }

  function _distributeReward(address _for) internal {
    DistributionInfo[] storage distribution = distributionInfo[_for];

    for (uint256 i = 0; i < distribution.length; i++) {
      uint256 periodTimes = _getPeriodTimes(distribution[i].lastUpdateBlock);

      if (periodTimes > 0 && distribution[i].remainingAmount > 0) {
        uint256 reward = distribution[i].rewardPerPeriod.mul(periodTimes);
        if (reward > distribution[i].remainingAmount) {
          reward = distribution[i].remainingAmount;
        }

        uint256 remainingAmount = distribution[i].remainingAmount.sub(reward);

        distribution[i].remainingAmount = remainingAmount;
        distribution[i].lastUpdateBlock = nextDistributionBlock;
        distributed = distributed.add(reward);

        token.safeTransfer(_for, reward);
        
        emit LogDistributeReward(_for, reward, remainingAmount);
      }
    }
  }

  function _getPeriodTimes(uint256 fromBlock) internal returns (uint256) {
    if (block.number < fromBlock) {
      return 0;
    }

    uint256 blocks = block.number.sub(fromBlock);
    return blocks.div(blockPerPeriod);
  }

  function removeMember(address _for) external nonReentrant onlyOwner {
    require(_for != address(0), "removeMember: invalid address");
    DistributionInfo[] storage distribution = distributionInfo[_for];
    require(distribution.length > 0, "removeMember: member not found");

    for (uint256 i = 0; i < distribution.length; i++) {
      uint256 remainingAmount = distribution[i].remainingAmount;

      // return avaliable distribution balance
      distributionBalance = distributionBalance.add(remainingAmount);

      emit LogRemoveMember(_for, remainingAmount);
    }

    // delete member from distribution
    delete distributionInfo[_for];

    // delete member from member list
    for (uint256 i = 0; i < members.length; i++) {
      if (members[i] == _for) {
        members[i] = members[members.length - 1];
        members.pop();
        break;
      }
    }
  }

  function memberList() public view returns (address[] memory) {
    address[] memory addrs = new address[](members.length);

    for (uint256 i = 0; i < members.length; i++) {
      addrs[i] = members[i];
    }

    return addrs;
  }

  function distributionList(address _for)
    public
    view
    returns (uint256[] memory totalAmount, uint256[] memory remainingAmount)
  {
    DistributionInfo[] storage distribution = distributionInfo[_for];

    totalAmount = new uint256[](distribution.length);
    remainingAmount = new uint256[](distribution.length);

    for (uint256 i = 0; i < distribution.length; i++) {
      totalAmount[i] = distribution[i].amount;
      remainingAmount[i] = distribution[i].remainingAmount;
    }
    return (totalAmount, remainingAmount);
  }

  function transferExceedAmount(address _to) external onlyOwner {
    require(_to != address(0), "PerformanceDistribution: cannot transfer exceed amount to zero address");
    uint256 totalBalance = token.balanceOf(address(this)).add(distributed);
    require(totalBalance > distributionCap, "PerformanceDistribution: balance is not exceed");
    token.safeTransfer(_to, totalBalance.sub(distributionCap));
  }

  function recoverAmountExceedGracePeriod(address _to) external onlyOwner {
    require(block.number >= gracePeriodBlock, "PerformanceDistribution: not exceed grace period yet");
    require(_to != address(0), "PerformanceDistribution: cannot recover amount to zero address");
    token.safeTransfer(_to, token.balanceOf(address(this)));
  }
}
