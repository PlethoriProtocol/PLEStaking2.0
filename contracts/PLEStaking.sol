// SPDX-License-Identifier: MIT

pragma solidity ^0.8.6;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./Initializable.sol";

interface IStaking {
    // Views
    function balanceOf(address account) external view returns (uint256);

    function unclaimedRewardsOf(address account)
        external
        view
        returns (uint256);

    // Mutative
    function stake(uint256 amount) external;

    function unstake(uint256 amount) external;

    function restakeRewards() external;

    function claimRewards() external;

    // Only Owner
    function switchFees(
        bool _takeStakeFee,
        bool _takeUnstakeFee,
        bool _takeRestakeFee
    ) external;

    function switchRewards(bool enableRewards) external;

    function emergencyWithdrawRewards(address emergencyAddress, uint256 amount)
        external;

    // Events
    event Staked(address account, uint256 amount);
    event Unstaked(address account, uint256 amount);
    event RestakedRewards(address account, uint256 amount);
    event ClaimedRewards(address account, uint256 amount);
    event PayedFee(address account, uint256 amount);
    event SwitchedFees(
        bool _takeStakeFee,
        bool _takeUnstakeFee,
        bool _takeRestakeFee
    );
    event SwitchedRewards(bool enableRewards);
    event RewardsWithdrawnEmergently(address emergencyAddress, uint256 amount);
}

contract PLEStaking is Ownable, Pausable, Initializable, IStaking {
    using SafeMath for uint256;

    IERC20 public token = IERC20(0x4e16cA03007820c1D0881eaD746Da14f8E69a4d2);
    address public feeAddress = 0x2658dE239e62AA3501b86cAeF700F4FF2fBAaE4E;

    // rewards & fees
    uint256 public constant REWARD_RATE = 4000; // 40.00% APY
    uint256 public constant STAKE_FEE_RATE = 150; // 1.50% staking fee
    uint256 public constant UNSTAKE_FEE_RATE = 50; // 0.50% unstaking fee
    uint256 public constant RESTAKE_FEE_RATE = 50; // 0.50% restaking fee
    bool public takeStakeFee;
    bool public takeUnstakeFee;
    bool public takeRestakeFee;
    uint256 public stopRewardsBlock;
    uint256 public availableRewards;

    // stake holders
    struct StakeHolder {
        uint256 stakedTokens;
        uint256 lastClaimedBlock;
        uint256 totalEarnedTokens;
    }
    uint256 public totalStaked;
    mapping(address => StakeHolder) public stakeHolders;

    // Views
    function balanceOf(address account)
        external
        view
        override
        returns (uint256)
    {
        return stakeHolders[account].stakedTokens;
    }

    function unclaimedRewardsOf(address account)
        external
        view
        override
        returns (uint256)
    {
        return _calculateUnclaimedRewards(account);
    }

    /**
     * Rewards Calculation:
     * rewards = (stakedTokens * blockDiff * rewardRatePerBlock)
     * rewardRatePerBlock =
     * 4000 (REWARD_RATE)
     * ------------------
     * 10000 * 365 (days/Y) * 24 (H/day) * 60 (M/H) * 4 (Blocks/M) = 21024e6
     */
    function _calculateUnclaimedRewards(address account)
        private
        view
        returns (uint256)
    {
        uint256 stakedTokens = stakeHolders[account].stakedTokens;
        if (stakedTokens == 0) return 0;
        // block diff calculation
        uint256 blockDiff = stakeHolders[account].lastClaimedBlock;
        if (stopRewardsBlock == 0) {
            blockDiff = block.number.sub(blockDiff);
        } else {
            if (stopRewardsBlock <= blockDiff) return 0;
            blockDiff = stopRewardsBlock.sub(blockDiff);
        }
        // rewards calculation
        uint256 unclaimedRewards = stakedTokens.mul(blockDiff).mul(REWARD_RATE);
        unclaimedRewards = unclaimedRewards.div(21024e6); // Audit: for gas efficieny
        if (unclaimedRewards > availableRewards) return 0;
        return unclaimedRewards;
    }

    // Mutative
    function stake(uint256 amount)
        external
        override
        whenNotPaused
        onlyInitialized
    {
        require(amount > 0, "Cannot stake 0 tokens");
        if (stakeHolders[msg.sender].stakedTokens > 0) {
            _restakeRewards(); // Audit: return value not check purposely
        } else {
            stakeHolders[msg.sender].lastClaimedBlock = block.number;
        }
        require(
            token.transferFrom(msg.sender, address(this), amount),
            "Could not transfer tokens from msg.sender to staking contract"
        );
        uint256 amountAfterFees = _takeFees(
            amount,
            takeStakeFee,
            STAKE_FEE_RATE
        );
        stakeHolders[msg.sender].stakedTokens = stakeHolders[msg.sender]
            .stakedTokens
            .add(amountAfterFees);
        totalStaked = totalStaked.add(amountAfterFees);
        emit Staked(msg.sender, amountAfterFees);
    }

    function unstake(uint256 amount)
        external
        override
        whenNotPaused
        onlyInitialized
    {
        require(amount > 0, "Cannot unstake 0 tokens");
        require(
            stakeHolders[msg.sender].stakedTokens >= amount,
            "Not enough tokens to unstake"
        );
        uint256 unclaimedRewards = _getRewards();
        stakeHolders[msg.sender].stakedTokens = stakeHolders[msg.sender]
            .stakedTokens
            .sub(amount);
        totalStaked = totalStaked.sub(amount);
        uint256 amountAfterFees = _takeFees(
            amount,
            takeUnstakeFee,
            UNSTAKE_FEE_RATE
        );
        if (unclaimedRewards > 0) {
            amountAfterFees = amountAfterFees.add(unclaimedRewards);
            emit ClaimedRewards(msg.sender, unclaimedRewards);
        }
        require(
            token.transfer(msg.sender, amountAfterFees),
            "Could not transfer tokens from staking contract to msg.sender"
        );
        emit Unstaked(msg.sender, amountAfterFees.sub(unclaimedRewards));
    }

    function restakeRewards() external override whenNotPaused onlyInitialized {
        require(_restakeRewards(), "Not rewards to restake");
    }

    function claimRewards() external override whenNotPaused onlyInitialized {
        uint256 unclaimedRewards = _getRewards();
        require(unclaimedRewards > 0, "Not rewards to claim");
        require(
            token.transfer(msg.sender, unclaimedRewards),
            "Could not transfer rewards from staking contract to msg.sender"
        );
        emit ClaimedRewards(msg.sender, unclaimedRewards);
    }

    // Mutative & Private
    function _restakeRewards() private returns (bool) {
        uint256 unclaimedRewards = _getRewards();
        if (unclaimedRewards == 0) return false;
        unclaimedRewards = _takeFees(
            unclaimedRewards,
            takeRestakeFee,
            RESTAKE_FEE_RATE
        );
        stakeHolders[msg.sender].stakedTokens = stakeHolders[msg.sender]
            .stakedTokens
            .add(unclaimedRewards);
        totalStaked = totalStaked.add(unclaimedRewards);
        emit RestakedRewards(msg.sender, unclaimedRewards);
        return true;
    }

    function _getRewards() private returns (uint256) {
        uint256 unclaimedRewards = _calculateUnclaimedRewards(msg.sender);
        if (unclaimedRewards == 0) return 0;
        availableRewards = availableRewards.sub(unclaimedRewards);
        stakeHolders[msg.sender].lastClaimedBlock = block.number;
        stakeHolders[msg.sender].totalEarnedTokens = stakeHolders[msg.sender]
            .totalEarnedTokens
            .add(unclaimedRewards);
        return unclaimedRewards;
    }

    function _takeFees(
        uint256 amount,
        bool takeFee,
        uint256 feeRate
    ) private returns (uint256) {
        if (takeFee) {
            uint256 fee = (amount.mul(feeRate)).div(1e4);
            require(token.transfer(feeAddress, fee), "Could not transfer fees");
            emit PayedFee(msg.sender, fee);
            return amount.sub(fee);
        }
        return amount;
    }

    // Only Owner
    function init() external onlyOwner whenNotPaused notInitialized {
        require(
            token.transferFrom(msg.sender, address(this), 8e6 ether),
            "Could not transfer 8,000,000 as rewards"
        );
        availableRewards = 8e6 ether;
        stopRewardsBlock = 0;
        takeStakeFee = false;
        takeUnstakeFee = true;
        takeRestakeFee = true;
        _init();
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function switchFees(
        bool _takeStakeFee,
        bool _takeUnstakeFee,
        bool _takeRestakeFee
    ) external override onlyOwner onlyInitialized {
        takeStakeFee = _takeStakeFee;
        takeUnstakeFee = _takeUnstakeFee;
        takeRestakeFee = _takeRestakeFee;
        emit SwitchedFees(_takeStakeFee, _takeUnstakeFee, _takeRestakeFee);
    }

    function switchRewards(bool enableRewards)
        external
        override
        onlyOwner
        onlyInitialized
    {
        if (enableRewards) {
            stopRewardsBlock = 0;
        } else {
            stopRewardsBlock = block.number;
        }
        emit SwitchedRewards(enableRewards);
    }

    function emergencyWithdrawRewards(address emergencyAddress, uint256 amount)
        external
        override
        onlyOwner
        onlyInitialized
    {
        require(
            availableRewards >= amount,
            "No available rewards for emergent withdrawal"
        );
        require(
            token.transfer(emergencyAddress, amount),
            "Could not transfer tokens"
        );
        availableRewards = availableRewards.sub(amount);
        emit RewardsWithdrawnEmergently(emergencyAddress, amount);
    }
}
