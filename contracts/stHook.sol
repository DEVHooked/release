// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract stHOOK is ERC20, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    IERC20 public immutable hookToken;
    uint256 public immutable startBlock;
    uint256 public immutable endBlock;
    uint256 public rewardPerBlock;
    uint256 public lastRewardBlock;
    uint256 public accRewardPerShare;
    uint256 public accruedRewards;
    uint256 public totalBoosterShare;
    uint256 public immutable quarterBlock;
    uint256 public immutable halfBlock;
    uint256 public immutable threeQuartersBlock;
    uint256 public constant PRECISION_FACTOR = 1e18;
    bool public paused = false;


    modifier notPaused() {
        require(!paused, "stHOOK: paused");
        _;
    }

    struct UserInfo {
        uint256 rewardDebt;
        uint256 lockedAmount;
        uint256 boosterShare;
    }

    mapping(address => UserInfo) public userInfo;

    constructor(
        IERC20 _hookToken,
        uint256 _startBlock,
        uint256 _endBlock,
        uint256 _rewardPerBlock
    ) ERC20("Staked Hook Token", "stHOOK") {
        hookToken = _hookToken;
        startBlock = _startBlock;
        endBlock = _endBlock;
        rewardPerBlock = _rewardPerBlock;
        lastRewardBlock = _startBlock;
        accRewardPerShare = 0;
        accruedRewards = 0;
        totalBoosterShare = 0;

        quarterBlock = _startBlock + (_endBlock - _startBlock) / 4;
        halfBlock = _startBlock + (_endBlock - _startBlock) / 2;
        threeQuartersBlock = _startBlock + 3 * (_endBlock - _startBlock) / 4;
    }

    function stake(uint256 _amount, bool _lock) public nonReentrant notPaused {
        hookToken.safeTransferFrom(msg.sender, address(this), _amount);
        updatePool();
        uint256 pending = pendingReward(msg.sender);
        if (pending > 0) {
            hookToken.safeTransfer(msg.sender, pending);
            emit Claim(msg.sender, pending);
        }
        _mint(msg.sender, _amount);
        if (_lock) {
            uint256 boost_factor;
            if (block.number <= quarterBlock) {
                boost_factor = 6;
            } else if (block.number <= halfBlock) {
                boost_factor = 3;
            } else if (block.number <= threeQuartersBlock) {
                boost_factor = 2;
            } else {
                boost_factor = 1;
            }
            userInfo[msg.sender].lockedAmount = userInfo[msg.sender].lockedAmount + _amount;
            uint256 remainingBlocks = endBlock - block.number;
            uint256 booster = _amount * remainingBlocks * boost_factor / (endBlock - startBlock);
            userInfo[msg.sender].boosterShare = userInfo[msg.sender].boosterShare + booster;
            totalBoosterShare = totalBoosterShare + booster;
        }

        accruedRewards = accruedRewards - pending;
        userInfo[msg.sender].rewardDebt = (balanceOf(msg.sender) + userInfo[msg.sender].boosterShare) * accRewardPerShare / PRECISION_FACTOR;
        emit Stake(msg.sender, _amount);
    }

    function withdraw(uint256 _amount) public nonReentrant notPaused {
        uint256 balanceOfUser = balanceOf(msg.sender);
        require(balanceOfUser >= _amount, "stHOOK: withdraw amount exceeds balance");
        if (block.number <= endBlock) {
            require(userInfo[msg.sender].lockedAmount <= balanceOfUser - _amount, "stHOOK: cannot withdraw locked tokens");
        }
        updatePool();
        
        uint256 pending = (balanceOf(msg.sender) + userInfo[msg.sender].boosterShare) * accRewardPerShare / PRECISION_FACTOR - userInfo[msg.sender].rewardDebt; 
        if(pending >0){
            emit Claim(msg.sender, pending);
        }
        require(hookToken.balanceOf(address(this)) >= pending + _amount, "stHOOK: insufficient balance");    
        _burn(msg.sender, _amount);
        hookToken.safeTransfer(msg.sender, _amount + pending);

        accruedRewards = accruedRewards - pending;
        userInfo[msg.sender].rewardDebt = (balanceOf(msg.sender) + userInfo[msg.sender].boosterShare) * accRewardPerShare / PRECISION_FACTOR;
        emit Withdraw(msg.sender, _amount);
    }

    function claim() public nonReentrant notPaused {
        updatePool();
        uint256 userCurrentReward = (balanceOf(msg.sender) + userInfo[msg.sender].boosterShare) * accRewardPerShare / PRECISION_FACTOR; 
        uint256 pending = userCurrentReward - userInfo[msg.sender].rewardDebt;
        
        require(hookToken.balanceOf(address(this)) >= pending, "stHOOK: insufficient balance");
        hookToken.safeTransfer(msg.sender, pending);

        accruedRewards = accruedRewards - pending;
        userInfo[msg.sender].rewardDebt = userCurrentReward;
        emit Claim(msg.sender, pending);
    }

    function updatePool() internal {
        if (block.number <= lastRewardBlock) {
            return;
        }
        if (totalSupply() == 0) {
            lastRewardBlock = block.number;
            return;
        }
        uint256 blockMultiplier = getBlockMultiplier(lastRewardBlock, block.number);

        uint256 tokenReward = blockMultiplier * rewardPerBlock;
        uint256 balance = hookToken.balanceOf(address(this));
        // If the rewards are insufficient, pause the contract. The rewards should be deposited by the owner.
        if (balance < tokenReward + accruedRewards + totalSupply()) {
            paused = true;
            emit Pause(paused);
        }
        accruedRewards = accruedRewards + tokenReward;
        accRewardPerShare = accRewardPerShare + (tokenReward * PRECISION_FACTOR / (totalSupply() + totalBoosterShare));
        
        lastRewardBlock = block.number;
    }

    function getBlockMultiplier(uint256 _lastRewardBlock, uint256 _currentBlock) public view returns (uint256) {
        if (_currentBlock <= startBlock) {
            return 0;
        } else if (_lastRewardBlock < startBlock){
            _lastRewardBlock = startBlock;
        }
        
        if (_currentBlock <= endBlock) {
            return _currentBlock - _lastRewardBlock;
        } else if (_lastRewardBlock >= endBlock) {
            return 0;
        } else {
            return endBlock - _lastRewardBlock;
        }
    }

    function pendingReward(address _user) public view returns (uint256) {
        uint256 _accRewardPerShare = accRewardPerShare;
        if (block.number > lastRewardBlock && totalSupply() != 0) {
            uint256 blockMultiplier = getBlockMultiplier(lastRewardBlock, block.number);
            uint256 tokenReward = blockMultiplier * rewardPerBlock;
            _accRewardPerShare = _accRewardPerShare + (tokenReward * PRECISION_FACTOR / (totalSupply() + totalBoosterShare));
            
        }
        return (balanceOf(_user) + userInfo[_user].boosterShare) * _accRewardPerShare / PRECISION_FACTOR - userInfo[_user].rewardDebt;
    }

    function increaseRewardsPerBlock(uint256 _newRewardPerBlock) public onlyOwner {
        require(_newRewardPerBlock > rewardPerBlock, "stHOOK: new reward must be greater than current reward");
        updatePool();
        rewardPerBlock = _newRewardPerBlock;
        emit IncreasedRewardPerBlock(rewardPerBlock, _newRewardPerBlock);
    }

    function pause() public onlyOwner {
        paused = true;
        emit Pause(paused);
    }

    function unpause() public onlyOwner {
        updatePool();
        uint256 balance = hookToken.balanceOf(address(this));
        require(balance >= accruedRewards + totalSupply() , "stHOOK: not enough rewards to resume");
        paused = false;
        emit Pause(paused);
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        require(from == address(0) || to == address(0), "stHOOK: token transfer restricted");
        super._beforeTokenTransfer(from, to, amount);
    }

    event Stake(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event Claim(address indexed user, uint256 amount);
    event Pause(bool paused);
    event IncreasedRewardPerBlock(uint256 oldRewardPerBlock, uint256 newRewardPerBlock);
}

