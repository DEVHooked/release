// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

contract CheckinSocial is ERC20, ReentrancyGuard, Ownable {
    
    using SafeERC20 for IERC20;

    IERC20 public immutable hookToken;

    address public signer;
    address public constant HOOK_SAFE = 0x370A740700D99b9FC27bF6A4A3aA4C96632f0914;
    bytes32 public constant CHECKIN_HASH_TYPE = keccak256("checkin");
    
    enum RoundStatus {NotStarted, Initialized, SettlePatch1, SettlePatch2, Settled}
    RoundStatus public roundStatus;

    uint256 public targetCheckinDays;      // Target check in days to get reward
    uint256 public durationDays;           // Completion duration days, should be greater than targetCheckinDays
    uint256 public depositStartTime;       // Deposit start time
    uint256 public checkinStartDay;        // Check in start day
    uint256 public amountPerShare;         // Amount per share 
    uint256 public maxSharePerUser;        // Max share per user
    uint256 public maxSupply;              // Max share supply
    uint256 public minCheckinDays;         // Min check in days to get deposit back
    address[] public checkinUsers;         // Status of check in users
    uint256 public totalRewardShare;       // Total reward share
    uint256 public rewardPerShare;         // Reward per share
    uint256 public settleIndex;            // Settle index

    uint256 public constant PRECISION_FACTOR = 1e18;

    struct CheckinInfo {
        uint256 checkinDays;  
        uint256 checkinDetail;  
    }

    mapping(address => CheckinInfo) public userCheckinInfo;  

    event InitializeRound(uint256 targetCheckinDays, uint256 durationDays, uint256 depositStartTime, uint256 checkinStartDay, 
        uint256 amountPerShare, uint256 maxSharePerUser, uint256 maxSupply);
    event Deposit(address indexed user, uint256 amount, uint256 share);
    event Checkin(address indexed user, uint256 checkinDays, uint256 checkinDetail);
    event Settle(uint256 totalRewardShare, uint256 rewardPerUser);

    constructor(IERC20 _hookToken, address _signer) ERC20("HOOK Learn Challenge", "HLC") {
        hookToken = _hookToken;
        signer = _signer;
        roundStatus = RoundStatus.NotStarted;
    }

    function initializeRound(uint256 _targetCheckinDays, uint256 _durationDays, uint256 _minCheckinDays, uint256 _depositStartTime, uint256 _checkinStartDay, 
        uint256 _amountPerShare, uint256 _maxSharePerUser, uint256 _maxTotalShare ) public nonReentrant onlyOwner {
        require(roundStatus == RoundStatus.NotStarted, "CheckinSocial: Round is already initialized");
        require(_durationDays >= _targetCheckinDays, "CheckinSocial: Completion duration should be greater than check in days");
        require(_durationDays <=256, "CheckinSocial: Completion duration should be less than 256 days");
        require(_minCheckinDays <= _targetCheckinDays, "CheckinSocial: Min check in days should be less than check in days");
        _checkinStartDay = calculateDay(_checkinStartDay);
        require(_depositStartTime<_checkinStartDay, "CheckinSocial: Check in start day should be greater than deposit start time");
        require(_depositStartTime >= block.timestamp, "CheckinSocial: Deposit start day should be greater than current time");

        targetCheckinDays = _targetCheckinDays;
        durationDays = _durationDays;
        minCheckinDays = _minCheckinDays;
        depositStartTime = _depositStartTime;
        checkinStartDay = _checkinStartDay;
        amountPerShare = _amountPerShare;
        maxSharePerUser = _maxSharePerUser*PRECISION_FACTOR; 
        maxSupply = _maxTotalShare*PRECISION_FACTOR;

        totalRewardShare = 0;
        settleIndex = 0;
        rewardPerShare = 0;

        roundStatus = RoundStatus.Initialized;
        emit InitializeRound(_targetCheckinDays,  _durationDays, _depositStartTime, _checkinStartDay, 
           _amountPerShare,  _maxSharePerUser,  _maxTotalShare);
    }

    function deposit(uint256 _share) public nonReentrant {
        require(roundStatus == RoundStatus.Initialized, "CheckinSocial: Round is not initialized");
        require(_share*PRECISION_FACTOR > 0, "CheckinSocial: Share should be greater than 0");
        require(block.timestamp >= depositStartTime, "CheckinSocial: Deposit is not started");
        require(block.timestamp < checkinStartDay, "CheckinSocial: Check in is started");
        uint256 balance = balanceOf(msg.sender);
        require(_share*PRECISION_FACTOR + balance <= maxSharePerUser, "CheckinSocial: Exceeds max deposit share per user");

        require(totalSupply() + _share*PRECISION_FACTOR <= maxSupply, "CheckinSocial: Exceeds max supply");
        
        userCheckinInfo[msg.sender].checkinDays = 0;
        userCheckinInfo[msg.sender].checkinDetail = 0;
        if (balance == 0){
            checkinUsers.push(msg.sender);
        }
        uint256 amount = _share * amountPerShare;
        hookToken.safeTransferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, _share*1e18);
        emit Deposit(msg.sender, amount, _share);
    }


    function checkin(bytes calldata signature) public nonReentrant {
        require(roundStatus == RoundStatus.Initialized, "CheckinSocial: Round is not initialized");
        require(balanceOf(msg.sender) > 0, "CheckinSocial: NOT deposited yet");
        require(block.timestamp >= checkinStartDay, "CheckinSocial: Check in is not started");
        require(block.timestamp < checkinStartDay + durationDays * 1 days, "CheckinSocial: Completion duration is exceeded");

        uint256 currentDay = calculateDay(block.timestamp);
        // Verify the signature
        bytes32 message = ECDSA.toEthSignedMessageHash(keccak256(abi.encodePacked(CHECKIN_HASH_TYPE, msg.sender, currentDay)));
        require(SignatureChecker.isValidSignatureNow(signer, message, signature),"CheckinSocial: Invalid signature");
        
        uint256 offset = (currentDay - checkinStartDay) / 1 days;
        uint256 checkinDetail = userCheckinInfo[msg.sender].checkinDetail;
        require((checkinDetail & (1 << offset)) == 0, "CheckinSocial: Already checked in today");
        
        userCheckinInfo[msg.sender].checkinDetail = checkinDetail | (1 << offset);
        userCheckinInfo[msg.sender].checkinDays = userCheckinInfo[msg.sender].checkinDays + 1;
        emit Checkin(msg.sender, userCheckinInfo[msg.sender].checkinDays, userCheckinInfo[msg.sender].checkinDetail);
    }
    
    function settlePatch1(uint256 batchSize) public nonReentrant onlyOwner {
        require(roundStatus == RoundStatus.Initialized || roundStatus == RoundStatus.SettlePatch1, "CheckinSocial: Round is not initialized");
        require(block.timestamp >= checkinStartDay + durationDays * 1 days, "CheckinSocial: Completion duration is not exceeded");
        
        roundStatus = RoundStatus.SettlePatch1;
        uint256 totalParticipants = checkinUsers.length;

        for (uint256 i = settleIndex; i < settleIndex + batchSize && i < totalParticipants; i++) {
            address user = checkinUsers[i];
            uint256 userCheckinDays = userCheckinInfo[user].checkinDays;
            uint256 share = balanceOf(user);

            if (userCheckinDays < minCheckinDays) {
                _burn(user, share);
            } else if (userCheckinDays < targetCheckinDays) {
                hookToken.safeTransfer(user, share / PRECISION_FACTOR * amountPerShare);
                _burn(user, share);
            } else {
                totalRewardShare += share;
            }
        }
        if (settleIndex + batchSize >= totalParticipants) {
            roundStatus = RoundStatus.SettlePatch2;
            uint256 totalBalance = hookToken.balanceOf(address(this));
            if (totalRewardShare == 0) {
                rewardPerShare = 0;
            } else {
                rewardPerShare = totalBalance * PRECISION_FACTOR / totalRewardShare;
            }
            settleIndex = 0;
        }else{
            settleIndex = settleIndex + batchSize;
        }

    }
    function settlePatch2(uint256 batchSize) public nonReentrant onlyOwner {
        require(roundStatus == RoundStatus.SettlePatch2, "CheckinSocial: SettlePatch1 is not finished");
        
        if (totalRewardShare == 0) {
            roundStatus = RoundStatus.Settled;
            hookToken.safeTransfer(HOOK_SAFE, hookToken.balanceOf(address(this)));
            emit Settle(totalRewardShare, rewardPerShare);
            return;
        }
        
        uint256 totalParticipants = checkinUsers.length;
        for (uint256 i = settleIndex; i < settleIndex + batchSize && i < totalParticipants; i++) {
            address user = checkinUsers[i];
            uint256 userCheckinDays = userCheckinInfo[user].checkinDays;
            if (userCheckinDays >= targetCheckinDays) {
                uint256 reward = balanceOf(user) * rewardPerShare / PRECISION_FACTOR ;
                hookToken.safeTransfer(user, reward);
                uint256 balance = balanceOf(user);
                _burn(user, balance);
            }
        }
        if (settleIndex + batchSize >= totalParticipants) {
            roundStatus = RoundStatus.Settled;
            emit Settle(totalRewardShare, rewardPerShare);
        }else{
            settleIndex = settleIndex + batchSize;
        }
        
        
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        require(from == address(0) || to == address(0), "CheckinSocial: Token transfer restricted");
        super._beforeTokenTransfer(from, to, amount);
    }

    function calculateDay(uint256 _timestamp) internal pure returns (uint256) {
        return _timestamp - (_timestamp % 1 days);
    }

    function setSigner(address _signer) public onlyOwner {
        signer = _signer;
    }

    function getUserCheckinDetailinArray(address user) public view returns (uint256[] memory) {
        uint256[] memory checkinDetail = new uint256[](durationDays);
        for (uint256 i = 0; i < durationDays; i++) {
            checkinDetail[i] = (userCheckinInfo[user].checkinDetail >> i) & 1;
        }
        return checkinDetail;
    }

    function getUserCheckinInfo(address user) external view returns (uint256, uint256[] memory) {
        return (userCheckinInfo[user].checkinDays, getUserCheckinDetailinArray(user));
    }

    function getCheckinUsers() external view returns (address[] memory){
        return checkinUsers;
    }
}
