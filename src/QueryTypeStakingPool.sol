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
  uint48 public lockupPeriod = 30 days;

  /// @notice The duration in seconds after the lockup period during which tokens can be withdrawn.
  uint48 public accessPeriod = 60 days;

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

  /// @notice A mapping that associates each staker with their signer.
  mapping(address staker => address signer) public stakerSigners;

  /// @notice The maximum allowed staking capacity.
  uint256 public stakingTokenCapacity;

  /// @notice The minimum required stake amount.
  uint256 public minimumStake;

  /// @notice The total amount of tokens currently staked in the pool.
  uint256 public totalStaked;

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

  /// @notice Emitted when the lockup period is updated
  event LockupPeriodUpdated(uint48 newPeriod);

  /// @notice Emitted when the access period is updated
  event AccessPeriodUpdated(uint48 newPeriod);

  /// @notice Emitted when the stakingTokenCapacity is updated.
  event StakingTokenCapacityUpdated(uint256 newCapacity);

  /// @notice Emitted when the minimum stake is updated.
  event MinimumStakeUpdated(uint256 newMinimumStake);

  /// @notice Emitted when tokens are unstaked.
  event Unstaked(address indexed staker, uint256 amount);

  /// @notice Emitted when a staker's signer is updated.
  event SignerUpdated(address indexed staker, address indexed oldSigner, address indexed newSigner);

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

  /// @notice Thrown when attempting to unstake during lockup period.
  error QueryTypeStakingPool__StillInLockupPeriod();

  /// @notice Thrown when attempting to unstake with no stake.
  error QueryTypeStakingPool__NoStakeFound();

  /// @notice Thrown when attempting to unstake more than staked amount.
  error QueryTypeStakingPool__InsufficientBalance();

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

  /// @notice Sets the lockup period duration
  /// @param _period The new lockup period in seconds
  function setLockupPeriod(uint48 _period) external {
    _checkOwner();
    lockupPeriod = _period;
    emit LockupPeriodUpdated(_period);
  }

  /// @notice Sets the access period duration
  /// @param _period The new access period in seconds
  function setAccessPeriod(uint48 _period) external {
    _checkOwner();
    accessPeriod = _period;
    emit AccessPeriodUpdated(_period);
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

    if (totalStaked + _amount > stakingTokenCapacity) {
      revert QueryTypeStakingPool__CapacityExceeded();
    }

    // Reset lockup and access periods
    StakeInfo memory stakeInfo = stakes[msg.sender];
    stakeInfo.lockupEnd = uint48(block.timestamp) + lockupPeriod;
    stakeInfo.accessEnd = stakeInfo.lockupEnd + accessPeriod;
    totalStaked += _amount;

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

  /// @notice Allows users to unstake their tokens after the lockup period.
  /// @param _amount The amount of tokens the user wishes to unstake.
  function unstake(uint256 _amount) external {
    StakeInfo storage userStake = stakes[msg.sender];
    if (userStake.amount == 0) revert QueryTypeStakingPool__NoStakeFound();
    if (block.timestamp < userStake.lockupEnd) revert QueryTypeStakingPool__StillInLockupPeriod();
    if (_amount > userStake.amount) revert QueryTypeStakingPool__InsufficientBalance();

    userStake.amount -= _amount;
    totalStaked -= _amount;
    STAKING_TOKEN.safeTransfer(msg.sender, _amount);

    emit Unstaked(msg.sender, _amount);
  }

  /// @notice Allows a staker to set or update their designated signer.
  /// @param _newSigner The address to set as the signer for the caller.
  function setSigner(address _newSigner) external {
    if (stakes[msg.sender].amount == 0) revert QueryTypeStakingPool__NoStakeFound();
    address oldSigner = stakerSigners[msg.sender];
    stakerSigners[msg.sender] = _newSigner;
    emit SignerUpdated(msg.sender, oldSigner, _newSigner);
  }
}
