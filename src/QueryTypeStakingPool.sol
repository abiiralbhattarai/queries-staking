// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title QueryTypeStakingPool
/// @author ScopeLift
/// @notice This contract manages staking of tokens for query type pools. Users can stake tokens for
/// a specified lockup and access period. During the lockup period, tokens cannot be withdrawn. After
/// the lockup period ends, users have an access period during which they can withdraw their tokens.
/// The contract maintains a conversion table history that tracks changes to the conversion rate
/// between staked tokens and query credits.
contract QueryTypeStakingPool is Ownable {
  using SafeERC20 for IERC20;

  /// @notice The duration in seconds that tokens will be locked after staking. During this period
  /// tokens cannot be withdrawn.
  uint48 public constant LOCKUP_PERIOD = 30 days;

  /// @notice The duration in seconds after the lockup period during which tokens can be withdrawn.
  uint48 public constant ACCESS_PERIOD = 60 days;

  /// @notice The array that stores the history of conversion table entries. Each entry represents a
  /// conversion rate between staked tokens and query credits at a point in time.
  bytes32[] public conversionTableHistory;

  /// @notice The ERC20 token contract that can be staked in this pool.
  IERC20 public immutable STAKING_TOKEN;

  /// @notice A struct containing information about a user's stake, including the amount staked, the
  /// index into the conversion table history at time of staking, and the lockup/access period end
  /// times.
  struct StakeInfo {
    uint256 amount;
    uint256 conversionTableIndex;
    uint48 lockupEnd;
    uint48 accessEnd;
  }

  /// @notice A mapping that associates staker addresses with their stake information.
  mapping(address staker => StakeInfo info) public stakes;

  /// @notice Emitted when a new conversion table entry is added to track changes in the conversion
  /// rate.
  event ConversionTableUpdated(bytes32 newEntry);

  /// @notice Emitted when tokens are staked, including details about the stake amount and timing.
  event Staked(
    address indexed staker,
    uint256 amount,
    uint256 conversionTableIndex,
    uint48 lockupEnd,
    uint48 accessEnd
  );

  /// @notice The maximum allowed staking capacity.
  uint256 public stakingTokenCapacity;

  /// @notice The minimum required stake amount.
  uint256 public minimumStake;

  /// @notice Emitted when the stakingTokenCapacity is updated.
  event StakingTokenCapacityUpdated(uint256 newCapacity);

  /// @notice Emitted when the minimum stake is updated.
  event MinimumStakeUpdated(uint256 newMinimumStake);

  /// @notice Thrown when attempting to stake with an invalid lockup period.
  error QueryTypeStakingPool__LockupPeriodTooLow();

  /// @notice Thrown when attempting to stake with an invalid access period.
  error QueryTypeStakingPool__AccessPeriodTooLow();

  /// @notice Thrown when a token transfer fails.
  error QueryTypeStakingPool__TokenTransferFailed();

  /// @notice Thrown when the staking amount is below the minimum required.
  error QueryTypeStakingPool__AmountBelowMinimum();

  /// @notice Thrown when staking exceeds the maximum allowed capacity.
  error QueryTypeStakingPool__CapacityExceeded();

  /// @notice Initializes the contract with the staking token address and initial conversion table
  /// entry.
  /// @param _owner The address that will own the contract and have permission to update the
  /// conversion table.
  /// @param _stakingToken The address of the ERC20 token that will be staked.
  /// @param _initialConversionTableEntry The first entry in the conversion table history.
  constructor(address _owner, address _stakingToken, bytes32 _initialConversionTableEntry)
    Ownable(_owner)
  {
    STAKING_TOKEN = IERC20(_stakingToken);

    // Initialize the conversion table with the provided entry
    conversionTableHistory.push(_initialConversionTableEntry);
    emit ConversionTableUpdated(_initialConversionTableEntry);
  }

  /// @notice Sets the global staking capacity.
  /// @param _capacity The new staking capacity.
  function setStakingTokenCapacity(uint256 _capacity) external {
    _checkOwner();
    stakingTokenCapacity = _capacity;
    emit StakingTokenCapacityUpdated(_capacity);
  }

  /// @notice Sets the minimum stake amount.
  /// @param _minimumStake The new minimum stake amount.
  function setMinimumStake(uint256 _minimumStake) external {
    _checkOwner();
    minimumStake = _minimumStake;
    emit MinimumStakeUpdated(_minimumStake);
  }

  /// @notice Adds a new conversion table entry to track changes in the conversion rate.
  /// @param _newEntry The new conversion table entry to add to the history.
  function updateConversionTable(bytes32 _newEntry) external {
    _checkOwner();
    conversionTableHistory.push(_newEntry);
    emit ConversionTableUpdated(_newEntry);
  }

  /// @notice Allows users to stake tokens for the predefined lockup and access periods.
  /// @param _amount The amount of tokens to stake.
  function stake(uint256 _amount) external {
    if (_amount < minimumStake) revert QueryTypeStakingPool__AmountBelowMinimum();

    uint256 totalStaked = STAKING_TOKEN.balanceOf(address(this));
    if (totalStaked + _amount > stakingTokenCapacity) {
      revert QueryTypeStakingPool__CapacityExceeded();
    }

    // Reset lockup and access periods
    StakeInfo memory stakeInfo = stakes[msg.sender];
    stakeInfo.lockupEnd = uint48(block.timestamp) + LOCKUP_PERIOD;
    stakeInfo.accessEnd = stakeInfo.lockupEnd + ACCESS_PERIOD;

    if (stakeInfo.amount == 0) {
      // First-time stake
      stakeInfo.amount = _amount;
      stakeInfo.conversionTableIndex = conversionTableHistory.length - 1;
      stakes[msg.sender] = stakeInfo;
      STAKING_TOKEN.safeTransferFrom(msg.sender, address(this), _amount);
      emit Staked(
        msg.sender,
        _amount,
        stakeInfo.conversionTableIndex,
        stakeInfo.lockupEnd,
        stakeInfo.accessEnd
      );
      return;
    }

    stakeInfo.amount += _amount;
    stakes[msg.sender] = stakeInfo;

    STAKING_TOKEN.safeTransferFrom(msg.sender, address(this), _amount);

    emit Staked(
      msg.sender, _amount, stakeInfo.conversionTableIndex, stakeInfo.lockupEnd, stakeInfo.accessEnd
    );
  }

  /// @notice Returns the total number of entries in the conversion table history.
  /// @return The length of the conversion table history array.
  function getConversionTableHistoryLength() external view returns (uint256) {
    return conversionTableHistory.length;
  }
}
