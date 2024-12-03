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

  /// @notice Thrown when attempting to stake zero tokens.
  error QueryTypeStakingPool__AmountTooLow();

  /// @notice Thrown when attempting to stake with an invalid lockup period.
  error QueryTypeStakingPool__LockupPeriodTooLow();

  /// @notice Thrown when attempting to stake with an invalid access period.
  error QueryTypeStakingPool__AccessPeriodTooLow();

  /// @notice Thrown when a token transfer fails.
  error QueryTypeStakingPool__TokenTransferFailed();

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
    if (_amount == 0) revert QueryTypeStakingPool__AmountTooLow();

    // Transfer tokens from user to pool using safeTransferFrom
    STAKING_TOKEN.safeTransferFrom(msg.sender, address(this), _amount);

    // Calculate timestamps
    uint48 lockupEnd = uint48(block.timestamp) + LOCKUP_PERIOD;
    uint48 accessEnd = lockupEnd + ACCESS_PERIOD;

    // Store stake information
    stakes[msg.sender] = StakeInfo({
      amount: _amount,
      conversionTableIndex: conversionTableHistory.length - 1,
      lockupEnd: lockupEnd,
      accessEnd: accessEnd
    });

    emit Staked(msg.sender, _amount, conversionTableHistory.length - 1, lockupEnd, accessEnd);
  }

  /// @notice Returns the total number of entries in the conversion table history.
  /// @return The length of the conversion table history array.
  function getConversionTableHistoryLength() external view returns (uint256) {
    return conversionTableHistory.length;
  }
}
