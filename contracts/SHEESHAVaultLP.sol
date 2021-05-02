// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./SHEESHA.sol";

contract SHEESHAVaultLP is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 checkpoint; //time user staked
        bool status; //true-> user existing | false-> not
        //
        // We do some fancy math here. Basically, any point in time, the amount of SHEESHAs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accSheeshaPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accSheeshaPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken; // Address of token/LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. SHEESHAs to distribute per block.
        uint256 lastRewardBlock; // Last block number that SHEESHAs distribution occurs.
        uint256 accSheeshaPerShare; // Accumulated SHEESHAs per share, times 1e12. See below.
    }

    // The SHEESHA TOKEN!
    SHEESHA public sheesha;
    
    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes  tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint;

    // The block number when SHEESHA mining starts.
    uint256 public startBlock;

    // SHEESHA tokens percenatge created per block based on rewards pool
    uint256 public sheeshaPerBlock;
    //handle case till 0.01(2 decimal places)
    uint256 public constant percentageDivider = 10000;
    //20,000 sheesha 20% of supply
    uint256 public lpRewards = 20000e18;
    address public feeWallet = 0x5483d944038189B4232d1E35367420989E2C3762;

    //user count
    uint256 public userCount;
    mapping(uint256 => address) public userList;

    mapping(address => bool) internal isExisting;
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );

    constructor(
        SHEESHA _sheesha,
        uint256 _startBlock,
        uint256 _lpRewards,
        uint256 _sheeshaPerBlock
    ) {
        sheesha = _sheesha;
        startBlock = _startBlock;
        lpRewards = _lpRewards;
        //for eth- 0.00475646879756469 == 4756468797564690
        //for bsc- 0.000951293759512938 == 951293759512938
        sheeshaPerBlock = _sheeshaPerBlock;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(
        uint256 _allocPoint,
        IERC20 _lpToken,
        bool _withUpdate
    ) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardBlock: lastRewardBlock,
                accSheeshaPerShare: 0
            })
        );
    }

    // Update the given pool's reward block. Can only be called by the owner.
    function setPoolLastRewardBlock(
        uint256 _pid,
        uint256 _lastRewardBlock
    ) public onlyOwner {
        poolInfo[_pid].lastRewardBlock = _lastRewardBlock;
    }

    function setPoolSheeshaPerShare(
        uint256 _pid,
        uint256 _accSheeshaPerShare
    ) public onlyOwner {
        poolInfo[_pid].accSheeshaPerShare = _accSheeshaPerShare;
    }

    // Update the given pool's SHEESHA allocation point. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        bool _withUpdate
    ) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // Update reward vairables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;

        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }

        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);

        uint256 sheeshaReward = multiplier.mul(sheeshaPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        
        //if rewards exhausted
        if(sheeshaReward > lpRewards) {
            sheeshaReward = lpRewards;
        }
        
        lpRewards = lpRewards.sub(sheeshaReward);

        pool.accSheeshaPerShare = pool.accSheeshaPerShare.add(sheeshaReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public pure returns (uint256) {
        return _to.sub(_from);
    }

    // Deposit LP tokens to MasterChef for SHEESHA allocation.
    function deposit(uint256 _pid, uint256 _amount) public {
        _deposit(msg.sender, _pid, _amount);
    }

    // stake from LGE directly
    // Test coverage
    // [x] Does user get the deposited amounts?
    // [x] Does user that its deposited for update correcty?
    // [x] Does the depositor get their tokens decreased
    function depositFor(address _depositFor, uint256 _pid, uint256 _amount) public {
        _deposit(_depositFor, _pid, _amount);
    }

    function _deposit(address _depositFor, uint256 _pid, uint256 _amount) internal nonReentrant {   
        if(!isUserExisting(_depositFor)) {
            userList[userCount] = _depositFor;
            userCount++;
            isExisting[_depositFor] = true;
        }
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_depositFor];

        updatePool(_pid);

        if(!isActive(_pid, _depositFor)) {
            user.status = true;
            user.checkpoint = block.timestamp;
        }

        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accSheeshaPerShare).div(1e12).sub(user.rewardDebt);
            safeSheeshaTransfer(_depositFor, pending);
        }

        if(_amount > 0) {
            //this should be msg.sender only because sender is depositing on someone's behalf
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount.add(_amount); // This is depositedFor address
        }

        user.rewardDebt = user.amount.mul(pool.accSheeshaPerShare).div(1e12); /// This is deposited for address
        emit Deposit(_depositFor, _pid, _amount);
    }

    // Withdraw LP tokens or claim rewrads if amount is 0
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accSheeshaPerShare).div(1e12).sub(user.rewardDebt);
        safeSheeshaTransfer(msg.sender, pending);
        if(_amount > 0) {
            uint256 feePercent = 4;
            //2 years
            if(block.timestamp <= user.checkpoint.add(730 days)) {
                //4-> unstake fee interval
                feePercent = uint256(100).sub(getElapsedMonthsCount(user.checkpoint).mul(4));
            }
            uint256 fees = _amount.mul(feePercent).div(100);
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(feeWallet, fees);
            pool.lpToken.safeTransfer(address(msg.sender), _amount.sub(fees));
        }
        user.rewardDebt = user.amount.mul(pool.accSheeshaPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    function isUserExisting(address _who)
        public
        view
        returns (bool)
    {
        return isExisting[_who];
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 feePercent = 4;
        //2 years
        if(block.timestamp <= user.checkpoint.add(730 days)) {
            //4-> unstake fee interval
            feePercent = uint256(100).sub(getElapsedMonthsCount(user.checkpoint).mul(4));
        }
        uint256 fees = user.amount.mul(feePercent).div(100);
        pool.lpToken.safeTransfer(feeWallet, fees);
        pool.lpToken.safeTransfer(address(msg.sender), user.amount.sub(fees));
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
    }

    function sync(uint256 _pid, address _addr, uint256 _amount, uint256 _rewardDebt, uint256 _checkPoint) public onlyOwner {
        if(!isUserExisting(_addr)) {
            userList[userCount] = _addr;
            userCount++;
            isExisting[_addr] = true;
        }
        
        UserInfo storage user = userInfo[_pid][_addr];
        user.rewardDebt = _rewardDebt;
        user.amount = _amount;
        user.checkpoint = _checkPoint;
        user.status = true;
    }

    //user must approve this contract to add rewards
    function addRewards(uint256 _amount) public onlyOwner {
        require(_amount > 0, "Invalid amount");
        IERC20(sheesha).safeTransferFrom(address(msg.sender), address(this), _amount);
        lpRewards = lpRewards.add(_amount);
    }

    // Safe sheesha transfer function, just in case if rounding error causes pool to not have enough SHEESHAs
    function safeSheeshaTransfer(address _to, uint256 _amount) internal {
        uint256 sheeshaBal = sheesha.balanceOf(address(this));
        if (_amount > sheeshaBal) {
            sheesha.transfer(_to, sheeshaBal);
        } else {
            sheesha.transfer(_to, _amount);
        }
    }

    // View function to see pending SHEESHAs on frontend.
    function pendingSheesha(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accSheeshaPerShare = pool.accSheeshaPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        uint256 _lpRewards = lpRewards;

        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 sheeshaReward = multiplier.mul(sheeshaPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accSheeshaPerShare = accSheeshaPerShare.add(sheeshaReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accSheeshaPerShare).div(1e12).sub(user.rewardDebt);
    }

    function isActive(uint256 _pid, address _user) public view returns(bool) {
        return userInfo[_pid][_user].status;
    }

    function getElapsedMonthsCount(uint256 checkpoint) public view returns(uint256) {
        return ((block.timestamp.sub(checkpoint)).div(30 days)).add(1);
    }

    function changeFeeWallet(address _feeWallet) external onlyOwner {
        feeWallet = _feeWallet;
    }

}