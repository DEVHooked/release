// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract stHOOKV2 is ERC20, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    IERC20 public immutable hookToken;
    uint256 public totalShares;
    bool public paused = false;
    uint256 public constant PRECISION_FACTOR = 1e18;
    uint256 public constant MIN_LOCK_DAYS = 30;
    uint256 public constant MAX_LOCK_DAYS = 1095;
    uint256 public startDay;
    uint256 public settledDay;

    struct UserInfo {
        uint256 rewardDebtPerShare;
        uint256 lockedAmount;
        uint256 boosterShare;
        uint256 lockTime;
        uint256 unlockDate;
    }

    mapping(uint256 => address[]) public unlockAddresses;
    mapping(address => UserInfo) public userInfo;

    uint256 public rewardPerDay;
    uint256 public accRewardPerShare;
    uint256 public accruedRewards;

    event Stake(address indexed user, uint256 amount, uint256 lockDays);
    event Withdraw(address indexed user, uint256 amount);
    event Claim(address indexed user, uint256 amount);
    event DailyRewardsSettled(uint256 date, uint256 totalRewards);
    event StakeAmountIncreased(address indexed user, uint256 additionalAmount);
    event LockPeriodExtended(address indexed user, uint256 additionalDays);
    event Pause(bool paused);

    modifier notPaused() {
        require(!paused, "stHOOKV2: paused");
        _;
    }

    constructor(IERC20 _hookToken, uint256 _rewardPerDay, uint256 _startDay) ERC20("Staked Hook Token V2", "stHOOKV2") {
        require(_startDay == (_startDay - (_startDay % 1 days)), "stHOOKV2: invalid start day");
        hookToken = _hookToken;
        rewardPerDay = _rewardPerDay;
        startDay = _startDay;
        settledDay = _startDay;
    }


    function setRewardPerDay(uint256 _rewardPerDay) public onlyOwner {
        require(_rewardPerDay > 0, "stHOOKV2: reward per day cannot be 0");
        rewardPerDay = _rewardPerDay;
    }


    function stake(uint256 _amount, uint256 _lockDays) public nonReentrant notPaused {
        require(_amount >= 1 ether, "stHOOKV2: cannot stake less than 1 HOOK");
        require(_lockDays >= MIN_LOCK_DAYS && _lockDays <= MAX_LOCK_DAYS, "stHOOKV2: invalid lock days");
        UserInfo storage user = userInfo[msg.sender];
        require(user.lockTime == 0, "stHOOKV2: existing stake not ended");

        user.lockTime = calculateStartOfDay(block.timestamp);
        user.unlockDate = calculateUnlockDate(user.lockTime, _lockDays);
        unlockAddresses[user.unlockDate].push(msg.sender);
        user.lockedAmount = _amount;
        user.boosterShare = calculateBoosterShare(_amount, _lockDays);
        totalShares += user.boosterShare + _amount;

        hookToken.safeTransferFrom(msg.sender, address(this), _amount);
        _mint(msg.sender, _amount);
        emit Stake(msg.sender, _amount, _lockDays);
    }

    function increaseStakeAmount(uint256 _additionalAmount) public nonReentrant notPaused {
        require(_additionalAmount > 1 ether, "stHOOKV2: cannot add less than 1 HOOK");
        UserInfo storage user = userInfo[msg.sender];
        require(user.lockTime != 0, "stHOOKV2: no active stake");
        require(block.timestamp < user.unlockDate, "stHOOKV2: tokens are already unlocked");

        claimReward();

        user.lockedAmount += _additionalAmount;
        uint256 additionalShares;

        additionalShares = calculateBoosterShare(_additionalAmount, (user.unlockDate - block.timestamp) / 1 days);
        user.boosterShare += additionalShares;
        totalShares += additionalShares + _additionalAmount;
        
        hookToken.safeTransferFrom(msg.sender, address(this), _additionalAmount);
        _mint(msg.sender, _additionalAmount);
        emit StakeAmountIncreased(msg.sender, _additionalAmount);
    }

    function extendLockPeriod(uint256 _additionalDays) public nonReentrant notPaused {
        require(_additionalDays > 0, "stHOOKV2: cannot add 0 days");
        UserInfo storage user = userInfo[msg.sender];
        require(user.lockTime != 0, "stHOOKV2: no active stake");
        require(block.timestamp < user.unlockDate, "stHOOKV2: tokens are already unlocked");

        claimReward();

        uint256 originalLockDays = (user.unlockDate - user.lockTime) / 1 days;
        uint256 newLockDays = originalLockDays + _additionalDays;
        require(newLockDays <= MAX_LOCK_DAYS, "stHOOKV2: lock period exceeds maximum");

        removeElement(unlockAddresses[user.unlockDate], msg.sender);

        user.unlockDate = calculateUnlockDate(user.lockTime, newLockDays);

        unlockAddresses[user.unlockDate].push(msg.sender);
        uint256 additionalShares = calculateBoosterShare(user.lockedAmount, _additionalDays);
        user.boosterShare += additionalShares;
        totalShares += additionalShares;

        emit LockPeriodExtended(msg.sender, _additionalDays);
    }

    function withdrawAll() public nonReentrant notPaused {
        uint256 currentDay = calculateDay(block.timestamp);
        require(currentDay == settledDay, "stHOOKV2: rewards not settled for today");
        UserInfo storage user = userInfo[msg.sender];
        require(block.timestamp > user.unlockDate, "stHOOKV2: tokens are still locked");

        uint256 rewardToClaim = pendingReward(msg.sender);
        uint256 totalAmount = user.lockedAmount + rewardToClaim;

        if (totalAmount > 0) {
            user.lockedAmount = 0;
            user.rewardDebtPerShare = 0;
            user.boosterShare = 0;
            user.lockTime = 0;
            hookToken.safeTransfer(msg.sender, totalAmount);
            _burn(msg.sender, user.lockedAmount);
        }
        accruedRewards -= rewardToClaim;
        emit Withdraw(msg.sender, user.lockedAmount);
    }

    function claim() public nonReentrant notPaused {
        claimReward();
    }

    function claimReward() internal {
        uint256 reward = pendingReward(msg.sender);

        if (reward > 0) {
            hookToken.safeTransfer(msg.sender, reward);

            UserInfo storage user = userInfo[msg.sender];
            user.rewardDebtPerShare = accRewardPerShare;
            accruedRewards -= reward;
            emit Claim(msg.sender, reward);
        }
    }

    function pendingReward(address _user) public view returns (uint256) {
        UserInfo storage user = userInfo[_user];
        uint256 userTotalShare = user.boosterShare + user.lockedAmount;
        return userTotalShare * (accRewardPerShare - user.rewardDebtPerShare) / PRECISION_FACTOR;
    }

    function settleRewards() public notPaused {
        uint256 currentDay = calculateDay(block.timestamp);
        require(currentDay > settledDay, "stHOOKV2: rewards already settled for today");
        require(currentDay > startDay, "stHOOKV2: rewards cannot be settled before start day");
        
        uint256 balance = hookToken.balanceOf(address(this));
        // If the contract balance is less than the daily reward and totalSupply, pause the contract
        if (balance < rewardPerDay + totalSupply()) {
            paused = true;
            emit Pause(paused);
        }

        uint256 targetDay = settledDay;

        for (uint256 i = 0; i < unlockAddresses[settledDay].length; i++) {
            address userAddress = unlockAddresses[settledDay][i];
            UserInfo storage user = userInfo[userAddress];

            totalShares -= user.boosterShare;
            user.boosterShare = 0;
        }

        accRewardPerShare = accRewardPerShare + (rewardPerDay * PRECISION_FACTOR / totalShares);
        settledDay = settledDay + 1 days;
        accruedRewards += rewardPerDay;

        emit DailyRewardsSettled(targetDay, accRewardPerShare);
    }

    // in case there are too many addresses to unlock in one transaction, pause the contract and run the patch
    function settleRewardsPatchStep1(uint256 startIndex, uint256 maxCount) public onlyOwner {
        uint256 currentDay = calculateDay(block.timestamp);
        require(currentDay > settledDay, "stHOOKV2: rewards already settled for today");
        require(currentDay > startDay, "stHOOKV2: rewards cannot be settled before start day");
        
        uint256 balance = hookToken.balanceOf(address(this));
        // If the contract balance is less than the reward and totalSupply, pause the contract
        if (balance < accruedRewards + totalSupply()) {
            paused = true;
            emit Pause(paused);
        }

        uint256 count = 0;
        for (uint256 i = startIndex; i < unlockAddresses[settledDay].length; i++) {
            address userAddress = unlockAddresses[settledDay][i];
            UserInfo storage user = userInfo[userAddress];

            totalShares -= user.boosterShare;
            user.boosterShare = 0;
            count++;
            if (count >= maxCount) {
                break;
            }
        }        
    }

    function settleRewardsPatchStep2() public onlyOwner {
        uint256 currentDay = calculateDay(block.timestamp);
        require(currentDay > settledDay, "stHOOKV2: rewards already settled for today");
        require(currentDay > startDay, "stHOOKV2: rewards cannot be settled before start day");

        uint256 targetDay = settledDay;

        accRewardPerShare = accRewardPerShare + (rewardPerDay * PRECISION_FACTOR / totalShares);
        settledDay = settledDay + 1 days;
        accruedRewards += rewardPerDay;

        emit DailyRewardsSettled(targetDay, accRewardPerShare);
    }

    function calculateDay(uint256 _timestamp) internal pure returns (uint256) {
        return _timestamp - (_timestamp % 1 days);
    }

    function calculateStartOfDay(uint256 _timestamp) internal view returns (uint256) {
        if (_timestamp < startDay) {
            return startDay;
        }
        return calculateDay(_timestamp);
    }

    function calculateUnlockDate(uint256 _startDay, uint256 _lockDays) internal pure returns (uint256) {
        uint256 unlockTimestamp = _startDay + _lockDays * 1 days;
        return unlockTimestamp;
    }

    function calculateBoosterShare(uint256 _amount, uint256 _lockDays) internal pure returns (uint256) {
        return _amount * _lockDays * 18 / MAX_LOCK_DAYS;
    }

    function removeElement(address[] storage array, address target) internal {
        for (uint256 i = 0; i < array.length; i++) {
            if (array[i] == target) {
                array[i] = array[array.length - 1];
                array.pop();
                break;
            }
        }
    }

    function pause() public onlyOwner {
        paused = true;
        emit Pause(paused);
    }

    function unpause() public onlyOwner {
        uint256 balance = hookToken.balanceOf(address(this));
        require(balance >= accruedRewards + totalSupply() , "stHOOKV2: insufficient contract balance");
        paused = false;
        emit Pause(paused);
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        require(from == address(0) || to == address(0), "stHOOKV2: token transfer restricted");
        super._beforeTokenTransfer(from, to, amount);
    }
}
