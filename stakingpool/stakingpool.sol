pragma solidity ^0.5.16;

import "https://github.com/avme/openzeppelin-contracts/blob/release-v2.4.0/contracts/math/Math.sol";
import "https://github.com/avme/openzeppelin-contracts/blob/release-v2.4.0/contracts/math/SafeMath.sol";
import "https://github.com/avme/openzeppelin-contracts/blob/release-v2.4.0/contracts/ownership/Ownable.sol";
import "https://github.com/avme/openzeppelin-contracts/blob/release-v2.4.0/contracts/token/ERC20/ERC20Detailed.sol";
import "https://github.com/avme/openzeppelin-contracts/blob/release-v2.4.0/contracts/token/ERC20/SafeERC20.sol";
import "https://github.com/avme/openzeppelin-contracts/blob/release-v2.4.0/contracts/utils/ReentrancyGuard.sol";

// Inheritance
import "./interfaces/IStakingRewards.sol";
import "./Pausable.sol";

// https://docs.synthetix.io/contracts/source/contracts/stakingrewards
contract StakingPool is IStakingRewards, ReentrancyGuard, Pausable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */

    IERC20 public rewardsToken; // AVME
    IERC20 public stakingToken; // LP
    uint256 public periodFinish = 0;  // Timestamp limit for staking rewards
    uint256 public rewardRate = 0;  // How many tokens will be distributed during rewards duration
    uint256 public rewardsDuration = 7 days;  // Time interval during which rewards will be distributed
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards; // Rewarded AVME balances for each user

    uint256 private _totalSupply; // Total LP currently in pool
    mapping(address => uint256) private _balances;  // LP balances for each user

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _owner,
        address _rewardsToken,
        address _stakingToken
    ) public Owned(_owner) {
        rewardsToken = IERC20(_rewardsToken);
        stakingToken = IERC20(_stakingToken);
    }

    /* ========== VIEWS ========== */
    function maxRewardSupply() external view returns (uint256) { return rewardsToken._maxSupply(); }
    function totalSupply() external view returns (uint256) { return _totalSupply; }
    function balanceOf(address account) external view returns (uint256) { return _balances[account]; }
    function lastTimeRewardApplicable() public view returns (uint256) { return Math.min(block.timestamp, periodFinish); }

    function rewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0) { return rewardPerTokenStored; }
        return rewardPerTokenStored.add(
            lastTimeRewardApplicable().sub(lastUpdateTime).mul(rewardRate).mul(1e18).div(_totalSupply)
        );
    }

    // Calculate how much AVME a given address has potentially earned so far
    function earned(address account) public view returns (uint256) {
        return _balances[account].mul(rewardPerToken().sub(userRewardPerTokenPaid[account])).div(1e18).add(rewards[account]);
    }

    // Get the total reward for the given duration
    function getRewardForDuration() external view returns (uint256) { return rewardRate.mul(rewardsDuration); }

    /* ========== MUTATIVE FUNCTIONS ========== */

    // Stake a given amount of LP
    function stake(uint256 amount) external nonReentrant notPaused updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");
        _totalSupply = _totalSupply.add(amount);
        _balances[msg.sender] = _balances[msg.sender].add(amount);
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    // Withdraw a given amount of LP
    function withdraw(uint256 amount) public nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot withdraw 0");
        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = _balances[msg.sender].sub(amount);
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    // Withdraw the accumulated reward in AVME so far
    function getReward() public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardsToken.safeMint(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
        if ((block.timestamp.add(43200)) > periodFinish) {
            calculateNewReward();
        }
    }

    // Get out of the pool and withdraw any remaining LP tokens/AVME rewards
    function exit() external {
        withdraw(_balances[msg.sender]);
        getReward();
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function notifyRewardAmount(uint256 reward) private updateReward(address(0)) {
        if (block.timestamp >= periodFinish) {
            rewardRate = reward.div(rewardsDuration);
        } else {
            uint256 remaining = periodFinish.sub(block.timestamp);
            uint256 leftover = remaining.mul(rewardRate);
            rewardRate = reward.add(leftover).div(rewardsDuration);
        }
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp.add(rewardsDuration);
        emit RewardAdded(reward);
    }
    
    function calculateNewReward() private {
        uint256 leftoverSupply = rewardsToken._maxSupply().sub(rewardsToken.totalSupply());
        uint256 rewardForNextDuration = leftoverSupply.div(10).div(52);
        notifyRewardAmount(rewardForNextDuration);
    }

    // Added to support recovering LP Rewards from other systems such as BAL to be distributed to holders
    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        require(tokenAddress != address(stakingToken), "Cannot withdraw the staking token");
        IERC20(tokenAddress).safeTransfer(owner, tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    // Set the time interval for rewards to be distributed
    function setRewardsDuration(uint256 _rewardsDuration) external onlyOwner {
        require(
            block.timestamp > periodFinish,
            "Previous rewards period must be complete before changing the duration for the new period"
        );
        rewardsDuration = _rewardsDuration;
        emit RewardsDurationUpdated(rewardsDuration);
    }

    /* ========== MODIFIERS ========== */

    // Update the reward for a given Account
    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    /* ========== EVENTS ========== */

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardsDurationUpdated(uint256 newDuration);
    event Recovered(address token, uint256 amount);
}

