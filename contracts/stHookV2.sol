// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract stHOOKV2 is ERC20, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    IERC20 public immutable hookToken;
    uint256 public totalShares;
    bool public paused;
    uint256 public constant PRECISION_FACTOR = 1e20;
    uint256 public constant MIN_LOCK_DAYS = 7;
    uint256 public constant MAX_LOCK_DAYS = 1095;
    uint256 public constant EXPIRED_DAY = 1830211200; // 2027-12-31 00:00:00 UTC
    uint256 public immutable startDay;
    uint256 public settledDay;
    uint256 public patchIndex;
    bool public isPatching;

    struct UserInfo {
        uint256 rewardDebtPerShare;
        uint256 lockedAmount;
        uint256 boosterShare;
        uint256 lockTime;
        uint256 unlockDate;
        uint256 fixedReward;
    }

    mapping(uint256 => EnumerableSet.AddressSet) private unlockAddresses;
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
    event SetRewardPerDay(uint256 rewardPerDay);

    modifier notPaused() {
        require(!paused, "stHOOKV2: paused");
        _;
    }

    constructor(IERC20 _hookToken, uint256 _rewardPerDay, uint256 _startDay) ERC20("Staked Hook Token V2", "stHOOKV2") {
        require(_hookToken != IERC20(address(0)), "stHOOKV2: invalid hook token");
        require(_startDay == (_startDay - (_startDay % 1 days)), "stHOOKV2: invalid start day");
        hookToken = _hookToken;
        rewardPerDay = _rewardPerDay;
        startDay = _startDay;
        settledDay = _startDay;
    }

    function getUnlockAddresses(uint256 _timestamp) public view returns (address[] memory) {
        uint256 day = calculateDay(_timestamp);
        uint256 unlockLength = unlockAddresses[day].length();
        address[] memory addresses = new address[](unlockLength);
        for (uint256 i = 0; i < unlockLength; i++) {
            addresses[i] = unlockAddresses[day].at(i);
        }
        return addresses;
    }
    
    function setRewardPerDay(uint256 _rewardPerDay) public onlyOwner {
        require(_rewardPerDay > 0, "stHOOKV2: reward per day cannot be 0");
        uint256 currentDay = calculateDay(block.timestamp);
        require(currentDay == settledDay, "stHOOKV2: The reward has not been settled yet for today");
        rewardPerDay = _rewardPerDay;

        emit SetRewardPerDay(_rewardPerDay);
    }


    function stake(uint256 _amount, uint256 _lockDays) public nonReentrant notPaused {
        uint256 currentDay = calculateDay(block.timestamp);
        require(currentDay >= startDay, "stHOOKV2: stake not started");
        require(currentDay == settledDay, "stHOOKV2: The reward has not been settled yet for today");

        require(_amount >= 1 ether, "stHOOKV2: cannot stake less than 1 HOOK");
        require(_lockDays >= MIN_LOCK_DAYS && _lockDays <= MAX_LOCK_DAYS, "stHOOKV2: invalid lock days");
        UserInfo storage user = userInfo[msg.sender];
        require(user.lockTime == 0, "stHOOKV2: existing stake not ended");

        user.lockTime = calculateStartOfDay(block.timestamp);
        user.unlockDate = calculateUnlockDate(user.lockTime, _lockDays);
        require(user.unlockDate <= EXPIRED_DAY, "stHOOKV2: lock period exceeds expiration date");
        require(unlockAddresses[user.unlockDate].add(msg.sender), "stHOOKV2: unlock address add failed");
        user.lockedAmount = _amount;
        user.boosterShare = calculateBoosterShare(_amount, _lockDays);
        user.rewardDebtPerShare = accRewardPerShare;
        totalShares += user.boosterShare + _amount;

        hookToken.safeTransferFrom(msg.sender, address(this), _amount);
        _mint(msg.sender, _amount);
        emit Stake(msg.sender, _amount, _lockDays);
    }

    function increaseStakeAmount(uint256 _additionalAmount) public nonReentrant notPaused {
        uint256 currentDay = calculateDay(block.timestamp);
        require(currentDay == settledDay, "stHOOKV2: The reward has not been settled yet for today");

        require(_additionalAmount >= 1 ether, "stHOOKV2: cannot add less than 1 HOOK");
        UserInfo storage user = userInfo[msg.sender];
        require(user.lockTime != 0, "stHOOKV2: no active stake");
        require(block.timestamp < user.unlockDate, "stHOOKV2: tokens are already unlocked");

        claimReward();

        user.lockedAmount += _additionalAmount;
        uint256 additionalShares;

        additionalShares = calculateBoosterShare(_additionalAmount, (user.unlockDate - block.timestamp) / 1 days + 1);
        user.boosterShare += additionalShares;
        totalShares += additionalShares + _additionalAmount;
        
        hookToken.safeTransferFrom(msg.sender, address(this), _additionalAmount);
        _mint(msg.sender, _additionalAmount);
        emit StakeAmountIncreased(msg.sender, _additionalAmount);
    }

    function extendLockPeriod(uint256 _additionalDays) public nonReentrant notPaused {
        uint256 currentDay = calculateDay(block.timestamp);
        require(currentDay == settledDay, "stHOOKV2: The reward has not been settled yet for today");

        require(_additionalDays > 0, "stHOOKV2: cannot add 0 days");
        UserInfo storage user = userInfo[msg.sender];
        require(user.lockTime != 0, "stHOOKV2: no active stake");
        require(block.timestamp < user.unlockDate, "stHOOKV2: tokens are already unlocked");

        claimReward();

        uint256 originalLockDays = (user.unlockDate - user.lockTime) / 1 days;
        uint256 newLockDays = originalLockDays + _additionalDays;
        require(newLockDays <= MAX_LOCK_DAYS, "stHOOKV2: lock period exceeds maximum");

        require(unlockAddresses[user.unlockDate].remove(msg.sender), "stHOOKV2: unlock address remove failed");

        user.unlockDate = calculateUnlockDate(user.lockTime, newLockDays);
        require(user.unlockDate <= EXPIRED_DAY, "stHOOKV2: lock period exceeds expiration date");

        require(unlockAddresses[user.unlockDate].add(msg.sender), "stHOOKV2: unlock address add failed");
        uint256 additionalShares = calculateBoosterShare(user.lockedAmount, _additionalDays);
        user.boosterShare += additionalShares;
        totalShares += additionalShares;

        emit LockPeriodExtended(msg.sender, _additionalDays);
    }

    function withdrawAll() public nonReentrant notPaused {
        uint256 currentDay = calculateDay(block.timestamp);
        require((currentDay == settledDay && currentDay <= EXPIRED_DAY) || (settledDay == EXPIRED_DAY && currentDay > EXPIRED_DAY), "stHOOKV2: rewards not settled for today");
        UserInfo storage user = userInfo[msg.sender];
        require(block.timestamp > user.unlockDate, "stHOOKV2: tokens are still locked");

        uint256 rewardToClaim = pendingReward(msg.sender);
        uint256 totalAmount = user.lockedAmount + rewardToClaim;
        uint256 lockAmount = user.lockedAmount;

        if (totalAmount > 0) {
            totalShares -= lockAmount + user.boosterShare;
            user.lockedAmount = 0;
            user.rewardDebtPerShare = 0;
            user.boosterShare = 0;
            user.lockTime = 0;
            user.fixedReward = 0;
            hookToken.safeTransfer(msg.sender, totalAmount);
            _burn(msg.sender, lockAmount);
        }
        accruedRewards -= rewardToClaim;
        emit Withdraw(msg.sender, lockAmount);
    }

    function claim() public nonReentrant notPaused {
        uint256 currentDay = calculateDay(block.timestamp);
        require((currentDay == settledDay && currentDay <= EXPIRED_DAY) || (settledDay == EXPIRED_DAY && currentDay > EXPIRED_DAY), "stHOOKV2: rewards not settled for today");

        claimReward();
    }

    function claimReward() internal {
        uint256 reward = pendingReward(msg.sender);

        if (reward > 0) {
            hookToken.safeTransfer(msg.sender, reward);

            UserInfo storage user = userInfo[msg.sender];
            user.rewardDebtPerShare = accRewardPerShare;
            user.fixedReward = 0;
            accruedRewards -= reward;
            emit Claim(msg.sender, reward);
        }
    }

    function pendingReward(address _user) public view returns (uint256) {
        UserInfo storage user = userInfo[_user];
        uint256 userTotalShare = user.boosterShare + user.lockedAmount; 
        return user.fixedReward + userTotalShare * (accRewardPerShare - user.rewardDebtPerShare) / PRECISION_FACTOR;
    }

    // run this function once a day to settle rewards for the previous day
    function settleRewards() public notPaused {
        require(isPatching == false , "stHOOKV2: patch had been started");
        uint256 currentDay = calculateDay(block.timestamp);
        require(currentDay > startDay, "stHOOKV2: rewards cannot be settled before start day");
        require(currentDay > settledDay, "stHOOKV2: rewards already settled for today");
        require(currentDay <= EXPIRED_DAY, "stHOOKV2: staking had expired");
        

        uint256 balance = hookToken.balanceOf(address(this));
        // If the contract balance is less than the daily reward and totalSupply, pause the contract
        if (balance < accruedRewards + rewardPerDay + totalSupply()) {
            paused = true;
            emit Pause(paused);
        }

        if (totalShares == 0) {
            settledDay = settledDay + 1 days;
            return;
        }

        accRewardPerShare = accRewardPerShare + (rewardPerDay * PRECISION_FACTOR / totalShares);
        accruedRewards += rewardPerDay;

        settledDay = settledDay + 1 days;
        
        uint256 unlockLength = unlockAddresses[settledDay].length();
        for (uint256 i = 0; i < unlockLength; i++) {
            address userAddress = unlockAddresses[settledDay].at(i);
            if (userAddress == address(0)) {
                continue;
            }
            UserInfo storage user = userInfo[userAddress];
            user.fixedReward = pendingReward(userAddress);
            user.rewardDebtPerShare = accRewardPerShare;
            totalShares -= user.boosterShare;
            user.boosterShare = 0;
        }

        emit DailyRewardsSettled(settledDay, accRewardPerShare);
    }

    // in case there are too many addresses to unlock in one transaction, pause the contract and run the patch
    function settleRewardsPatchStep1() public onlyOwner {
        require(isPatching == false, "stHOOKV2: settleRewardsPatchStep2 hadn't complete");
        uint256 currentDay = calculateDay(block.timestamp);
        require(currentDay > settledDay, "stHOOKV2: rewards already settled for today");
        require(currentDay > startDay, "stHOOKV2: rewards cannot be settled before start day");
        require(currentDay <= EXPIRED_DAY, "stHOOKV2: staking had expired");
        
        uint256 balance = hookToken.balanceOf(address(this));
        // If the contract balance is less than the reward and totalSupply, pause the contract
        if (balance < accruedRewards + rewardPerDay + totalSupply()) {
            paused = true;
            emit Pause(paused);
        }

        if (totalShares == 0) {
            settledDay = settledDay + 1 days;
            return;
        }

        accRewardPerShare = accRewardPerShare + (rewardPerDay * PRECISION_FACTOR / totalShares);
        accruedRewards += rewardPerDay;
        
        settledDay = settledDay + 1 days;
        isPatching = true;
    }

    function settleRewardsPatchStep2(uint256 batchSize) public onlyOwner {
        require(isPatching == true, "stHOOKV2: settleRewardsPatchStep1 hadn't began");

        uint256 currentDay = calculateDay(block.timestamp);
        require(currentDay > startDay, "stHOOKV2: rewards cannot be settled before start day");
        require(currentDay <= EXPIRED_DAY, "stHOOKV2: staking had expired");
        
        uint256 unlockLength = unlockAddresses[settledDay].length();
        uint256 endIndex = (patchIndex + batchSize) < unlockLength ? (patchIndex + batchSize) : unlockLength;

        for (uint256 i = patchIndex; i < endIndex; i++) {
            address userAddress = unlockAddresses[settledDay].at(i);

            UserInfo storage user = userInfo[userAddress];
            user.fixedReward = pendingReward(userAddress);
            user.rewardDebtPerShare = accRewardPerShare;
            totalShares -= user.boosterShare;
            user.boosterShare = 0;
        }

        patchIndex = endIndex;

        if(patchIndex == unlockLength){
            isPatching = false;
            patchIndex = 0;
            emit DailyRewardsSettled(settledDay, accRewardPerShare);
        }
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

    function pause() public onlyOwner {
        paused = true;
        emit Pause(paused);
    }

    function unpause() public onlyOwner {
        uint256 balance = hookToken.balanceOf(address(this));
        require(balance >= (accruedRewards + rewardPerDay + totalSupply()) , "stHOOKV2: insufficient contract balance");
        paused = false;
        emit Pause(paused);
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        require(from == address(0) || to == address(0), "stHOOKV2: token transfer restricted");
        super._beforeTokenTransfer(from, to, amount);
    }
}
