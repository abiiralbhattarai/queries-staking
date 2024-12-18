// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {QueryTypeStakingPool} from "src/QueryTypeStakingPool.sol";
import {QueryTypeStakerFactory} from "src/QueryTypeStakerFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract QueryTypeStakingPoolTest is Test {
  QueryTypeStakingPool public pool;
  MockERC20 public stakingToken;
  address public factory;
  address public staker;
  uint256 public constant INITIAL_BALANCE = 1_000_000_000 ether;
  uint256 public constant MAX_TIME_SKIP = 1000 * 365 days;

  function setUp() public virtual {
    staker = makeAddr("staker");
    stakingToken = new MockERC20();
    factory = makeAddr("factory");
    bytes32 initialEntry = bytes32(uint256(1));
    pool = new QueryTypeStakingPool(address(this), address(stakingToken), initialEntry);

    // Setup initial balance and approvals
    stakingToken.mint(staker, INITIAL_BALANCE);
    vm.prank(staker);
    stakingToken.approve(address(pool), type(uint256).max);
  }
}

contract Constructor is QueryTypeStakingPoolTest {
  function testFuzz_SetsStakingTokenCorrectly(
    address _owner,
    address _stakingToken,
    bytes32 _initialEntry
  ) public {
    vm.assume(_owner != address(0));
    vm.assume(_stakingToken != address(0));

    QueryTypeStakingPool newPool = new QueryTypeStakingPool(_owner, _stakingToken, _initialEntry);
    assertEq(address(newPool.STAKING_TOKEN()), _stakingToken);
    assertEq(newPool.conversionTableHistory(0), _initialEntry);
  }
}

contract UpdateConversionTable is QueryTypeStakingPoolTest {
  function test_CorrectlyInitializesConversionTableEntry() public view {
    // Check that the constructor set the initial entry correctly
    assertEq(pool.conversionTableHistory(0), bytes32(uint256(1)));
  }

  function testFuzz_CorrectlyUpdatesConversionTableHistory(bytes32 _newEntry) public {
    uint256 currentIndex = pool.getConversionTableHistoryLength();

    vm.expectEmit();
    emit QueryTypeStakingPool.ConversionTableUpdated(_newEntry);

    pool.updateConversionTable(_newEntry);

    assertEq(pool.conversionTableHistory(currentIndex), _newEntry);
  }

  function testFuzz_RevertIf_CallerIsNotOwner(address _notOwner, bytes32 _newEntry) public {
    vm.assume(_notOwner != address(0));
    vm.assume(_notOwner != address(this));
    vm.prank(_notOwner);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _notOwner));
    pool.updateConversionTable(_newEntry);
  }
}

contract Stake is QueryTypeStakingPoolTest {
  function testFuzz_StakesTokensSuccessfully(
    uint256 _amount,
    bytes32 _conversionEntry,
    uint256 _capacity
  ) public {
    _amount = bound(_amount, 1, INITIAL_BALANCE);
    _capacity = bound(_capacity, _amount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);
    pool.updateConversionTable(_conversionEntry);
    uint256 expectedIndex = pool.getConversionTableHistoryLength() - 1;

    uint256 expectedLockupEnd = block.timestamp + pool.lockupPeriod();
    uint256 expectedAccessEnd = expectedLockupEnd + pool.accessPeriod();

    vm.prank(staker);
    pool.stake(_amount);

    (uint256 stakedAmount, uint256 conversionTableIndex, uint48 lockupEnd, uint48 accessEnd) =
      pool.stakes(staker);

    assertEq(stakedAmount, _amount);
    assertEq(conversionTableIndex, expectedIndex);
    assertEq(lockupEnd, expectedLockupEnd);
    assertEq(accessEnd, expectedAccessEnd);
    assertEq(stakingToken.balanceOf(address(pool)), _amount);
    assertEq(pool.totalStaked(), _amount);
  }

  function testFuzz_UpdatesExistingStakeCorrectly(
    uint256 _initialAmount,
    uint256 _additionalAmount,
    uint256 _capacity
  ) public {
    _initialAmount = bound(_initialAmount, 1, INITIAL_BALANCE / 2);
    _additionalAmount = bound(_additionalAmount, 0, INITIAL_BALANCE - _initialAmount);
    _capacity = bound(_capacity, _initialAmount + _additionalAmount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);

    vm.prank(staker);
    pool.stake(_initialAmount);

    (, uint256 originalIndex,,) = pool.stakes(staker);

    // Advance time a bit to ensure timestamps change
    vm.warp(block.timestamp + 1 days);

    vm.prank(staker);
    pool.stake(_additionalAmount);

    (uint256 finalAmount, uint256 finalIndex, uint48 finalLockupEnd, uint48 finalAccessEnd) =
      pool.stakes(staker);

    assertEq(finalAmount, _initialAmount + _additionalAmount, "Total stake amount incorrect");
    assertEq(finalIndex, originalIndex, "Conversion table index should not change");
    assertEq(finalLockupEnd, block.timestamp + pool.lockupPeriod(), "Lockup end incorrect");
    assertEq(finalAccessEnd, finalLockupEnd + pool.accessPeriod(), "Access end incorrect");
    assertEq(
      stakingToken.balanceOf(address(pool)),
      _initialAmount + _additionalAmount,
      "Pool balance incorrect"
    );
    assertEq(
      pool.totalStaked(), _initialAmount + _additionalAmount, "Total staked amount incorrect"
    );
  }

  function testFuzz_StakeCalculatesEndTimesWithNewPeriods(
    uint256 _amount,
    uint48 _newLockupPeriod,
    uint48 _newAccessPeriod,
    uint256 _capacity
  ) public {
    _amount = bound(_amount, 1, INITIAL_BALANCE);
    _newLockupPeriod = uint48(bound(_newLockupPeriod, 0, 1000 days));
    _newAccessPeriod = uint48(bound(_newAccessPeriod, 0, 1000 days));
    _capacity = bound(_capacity, _amount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);
    pool.setLockupPeriod(_newLockupPeriod);
    pool.setAccessPeriod(_newAccessPeriod);

    uint256 expectedLockupEnd = block.timestamp + _newLockupPeriod;
    uint256 expectedAccessEnd = expectedLockupEnd + _newAccessPeriod;

    vm.prank(staker);
    pool.stake(_amount);

    (,, uint48 lockupEnd, uint48 accessEnd) = pool.stakes(staker);

    assertEq(lockupEnd, expectedLockupEnd);
    assertEq(accessEnd, expectedAccessEnd);
  }

  function testFuzz_EmitsStakeEvent(uint256 _amount, bytes32 _conversionEntry, uint256 _capacity)
    public
  {
    _amount = bound(_amount, 1, INITIAL_BALANCE);
    _capacity = bound(_capacity, _amount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);
    pool.updateConversionTable(_conversionEntry);
    uint256 expectedIndex = pool.getConversionTableHistoryLength() - 1;

    uint48 expectedLockupEnd = uint48(block.timestamp) + pool.lockupPeriod();
    uint48 expectedAccessEnd = expectedLockupEnd + pool.accessPeriod();

    vm.expectEmit();
    emit QueryTypeStakingPool.Staked(
      staker, _amount, expectedIndex, expectedLockupEnd, expectedAccessEnd
    );

    vm.prank(staker);
    pool.stake(_amount);
  }

  function testFuzz_RevertIf_InsufficientBalance(uint256 _amount, uint256 _capacity) public {
    _amount = bound(_amount, INITIAL_BALANCE + 1, type(uint256).max);
    _capacity = bound(_capacity, _amount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);

    vm.prank(staker);
    vm.expectRevert(
      abi.encodeWithSignature(
        "ERC20InsufficientBalance(address,uint256,uint256)", staker, INITIAL_BALANCE, _amount
      )
    );
    pool.stake(_amount);
  }

  function testFuzz_RevertIf_TokenTransferFails(uint256 _amount, uint256 _capacity) public {
    _amount = bound(_amount, 1, INITIAL_BALANCE);
    _capacity = bound(_capacity, _amount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);
    stakingToken.setTransferFromShouldFail(true);

    vm.prank(staker);
    vm.expectRevert(
      abi.encodeWithSelector(
        bytes4(keccak256("SafeERC20FailedOperation(address)")), address(stakingToken)
      )
    );
    pool.stake(_amount);
  }

  function testFuzz_RevertIf_ExceedsCapacity(uint256 _amount, uint256 _capacity) public {
    _amount = bound(_amount, 1, INITIAL_BALANCE);
    _capacity = bound(_capacity, 0, _amount - 1);

    pool.setStakingTokenCapacity(_capacity);

    vm.prank(staker);
    vm.expectRevert(QueryTypeStakingPool.QueryTypeStakingPool__CapacityExceeded.selector);
    pool.stake(_amount);
  }

  function testFuzz_RevertIf_StakeAmountBelowMinimum(
    uint256 _amount,
    uint256 _minimumStake,
    uint256 _capacity
  ) public {
    // Ensure amount is greater than 0 but less than minimum stake
    _minimumStake = bound(_minimumStake, 2, INITIAL_BALANCE);
    _amount = bound(_amount, 1, _minimumStake - 1);
    _capacity = bound(_capacity, _amount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);
    pool.setMinimumStake(_minimumStake);

    vm.prank(staker);
    vm.expectRevert(QueryTypeStakingPool.QueryTypeStakingPool__AmountBelowMinimum.selector);
    pool.stake(_amount);
  }

  function testFuzz_RevertIf_AddressIsBlocklisted(uint256 _amount, uint256 _capacity) public {
    _amount = bound(_amount, 1, INITIAL_BALANCE);
    _capacity = bound(_capacity, _amount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);

    // Setup initial stake to allow blocklisting
    vm.prank(staker);
    pool.stake(_amount);

    // Blocklist the staker
    pool.blocklist(staker);

    // Try to stake more
    vm.prank(staker);
    vm.expectRevert(QueryTypeStakingPool.QueryTypeStakingPool__AddressBlocklisted.selector);
    pool.stake(_amount);
  }
}

contract GetConversionTableHistoryLength is QueryTypeStakingPoolTest {
  function test_ReturnsCorrectLength() public {
    // Initial length should be 1 due to initialEntry in constructor
    assertEq(pool.getConversionTableHistoryLength(), 1);

    // Add 100 new random entries and verify length increases
    for (uint256 i = 2; i <= 100; i++) {
      bytes32 randomEntry = keccak256(abi.encodePacked(block.timestamp, i, msg.sender));
      pool.updateConversionTable(randomEntry);
      assertEq(pool.getConversionTableHistoryLength(), i);
    }

    // Final length should be 100
    assertEq(pool.getConversionTableHistoryLength(), 100);
  }
}

contract SetStakingTokenCapacity is QueryTypeStakingPoolTest {
  function testFuzz_SetStakingTokenCapacitySuccessfully(uint256 _newCapacity) public {
    pool.setStakingTokenCapacity(_newCapacity);
    assertEq(pool.stakingTokenCapacity(), _newCapacity);
  }

  function testFuzz_SetStakingTokenCapacityEmitsEvent(uint256 _newCapacity) public {
    vm.expectEmit();
    emit QueryTypeStakingPool.StakingTokenCapacityUpdated(_newCapacity);

    pool.setStakingTokenCapacity(_newCapacity);
  }

  function testFuzz_SetStakingTokenCapacity_RevertIf_NotOwner(
    address _notOwner,
    uint256 _newCapacity
  ) public {
    vm.assume(_notOwner != address(this)); // not owner

    vm.prank(_notOwner);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _notOwner));
    pool.setStakingTokenCapacity(_newCapacity);
  }
}

contract SetMinimumStake is QueryTypeStakingPoolTest {
  function testFuzz_SetMinimumStakeSuccessfully(uint256 _newMinimumStake) public {
    pool.setMinimumStake(_newMinimumStake);
    assertEq(pool.minimumStake(), _newMinimumStake);
  }

  function testFuzz_SetMinimumStakeEmitsEvent(uint256 _newMinimumStake) public {
    vm.expectEmit();
    emit QueryTypeStakingPool.MinimumStakeUpdated(_newMinimumStake);

    pool.setMinimumStake(_newMinimumStake);
  }

  function testFuzz_SetMinimumStake_RevertIf_NotOwner(address caller, uint256 amount) public {
    vm.assume(caller != address(0) && caller != address(this));

    vm.prank(caller);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
    pool.setMinimumStake(amount);
  }
}

contract SetLockupPeriod is QueryTypeStakingPoolTest {
  function testFuzz_SetLockupPeriodSuccessfully(uint48 _newPeriod) public {
    pool.setLockupPeriod(_newPeriod);
    assertEq(pool.lockupPeriod(), _newPeriod);
  }

  function testFuzz_SetLockupPeriodEmitsEvent(uint48 _newPeriod) public {
    vm.expectEmit();
    emit QueryTypeStakingPool.LockupPeriodUpdated(_newPeriod);

    pool.setLockupPeriod(_newPeriod);
  }

  function testFuzz_SetLockupPeriod_RevertIf_NotOwner(address _notOwner, uint48 _newPeriod) public {
    vm.assume(_notOwner != address(this));
    vm.prank(_notOwner);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _notOwner));
    pool.setLockupPeriod(_newPeriod);
  }
}

contract SetAccessPeriod is QueryTypeStakingPoolTest {
  function testFuzz_SetAccessPeriodSuccessfully(uint48 _newPeriod) public {
    pool.setAccessPeriod(_newPeriod);
    assertEq(pool.accessPeriod(), _newPeriod);
  }

  function testFuzz_SetAccessPeriodEmitsEvent(uint48 _newPeriod) public {
    vm.expectEmit();
    emit QueryTypeStakingPool.AccessPeriodUpdated(_newPeriod);

    pool.setAccessPeriod(_newPeriod);
  }

  function testFuzz_SetAccessPeriod_RevertIf_NotOwner(address _notOwner, uint48 _newPeriod) public {
    vm.assume(_notOwner != address(this));
    vm.prank(_notOwner);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _notOwner));
    pool.setAccessPeriod(_newPeriod);
  }
}

contract Unstake is QueryTypeStakingPoolTest {
  function testFuzz_UnstakeSuccessfully(
    uint256 _stakeAmount,
    uint256 _unstakeAmount,
    uint256 _timeSkip,
    uint256 _capacity
  ) public {
    _stakeAmount = bound(_stakeAmount, 1, INITIAL_BALANCE);
    _unstakeAmount = bound(_unstakeAmount, 1, _stakeAmount);
    _timeSkip = bound(_timeSkip, pool.lockupPeriod() + 1, MAX_TIME_SKIP);
    _capacity = bound(_capacity, _stakeAmount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);

    // Initial stake
    vm.prank(staker);
    pool.stake(_stakeAmount);

    // Warp to valid unstake time
    vm.warp(block.timestamp + _timeSkip);
    uint256 initialBalance = stakingToken.balanceOf(staker);

    vm.prank(staker);
    pool.unstake(_unstakeAmount);

    assertEq(stakingToken.balanceOf(staker), initialBalance + _unstakeAmount);
    (uint256 remainingStake,,,) = pool.stakes(staker);
    assertEq(remainingStake, _stakeAmount - _unstakeAmount);
    assertEq(pool.totalStaked(), _stakeAmount - _unstakeAmount);
  }

  function testFuzz_UnstakeAfterMultipleStakes(
    uint256 _initialStake,
    uint256 _additionalStake,
    uint256 _unstakeAmount,
    uint256 _timeSkip,
    uint256 _capacity
  ) public {
    _initialStake = bound(_initialStake, 1, INITIAL_BALANCE / 2);
    _additionalStake = bound(_additionalStake, 0, INITIAL_BALANCE - _initialStake);
    uint256 totalStaked = _initialStake + _additionalStake;
    _unstakeAmount = bound(_unstakeAmount, 1, totalStaked);
    _timeSkip = bound(_timeSkip, pool.lockupPeriod() + 1, MAX_TIME_SKIP);
    _capacity = bound(_capacity, totalStaked, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);

    // Initial stake
    vm.prank(staker);
    pool.stake(_initialStake);

    // Additional stake
    vm.prank(staker);
    pool.stake(_additionalStake);

    // Warp to valid unstake time
    vm.warp(block.timestamp + _timeSkip);

    uint256 initialBalance = stakingToken.balanceOf(staker);

    vm.prank(staker);
    pool.unstake(_unstakeAmount);

    assertEq(stakingToken.balanceOf(staker), initialBalance + _unstakeAmount);
    (uint256 remainingStake,,,) = pool.stakes(staker);
    assertEq(remainingStake, totalStaked - _unstakeAmount);
    assertEq(stakingToken.balanceOf(address(pool)), totalStaked - _unstakeAmount);
    assertEq(pool.totalStaked(), totalStaked - _unstakeAmount);
  }

  function testFuzz_RevertIf_TokenTransferFails(
    uint256 _stakeAmount,
    uint256 _unstakeAmount,
    uint256 _timeSkip,
    uint256 _capacity
  ) public {
    _stakeAmount = bound(_stakeAmount, 1, INITIAL_BALANCE);
    _unstakeAmount = bound(_unstakeAmount, 1, _stakeAmount);
    _timeSkip = bound(_timeSkip, pool.lockupPeriod() + 1, MAX_TIME_SKIP);
    _capacity = bound(_capacity, _stakeAmount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);

    // Initial stake
    vm.prank(staker);
    pool.stake(_stakeAmount);

    // Warp to valid unstake time
    vm.warp(block.timestamp + _timeSkip);

    // Make transfer fail
    stakingToken.setTransferShouldFail(true);

    vm.prank(staker);
    vm.expectRevert(
      abi.encodeWithSelector(
        bytes4(keccak256("SafeERC20FailedOperation(address)")), address(stakingToken)
      )
    );
    pool.unstake(_unstakeAmount);
  }

  function testFuzz_RevertIf_StillInLockup(
    uint256 _stakeAmount,
    uint256 _unstakeAmount,
    uint256 _timeSkip,
    uint256 _capacity
  ) public {
    _stakeAmount = bound(_stakeAmount, 1, INITIAL_BALANCE);
    _unstakeAmount = bound(_unstakeAmount, 1, _stakeAmount);
    // Bound time skip to be before lockup period ends
    _timeSkip = bound(_timeSkip, 0, pool.lockupPeriod() - 1);
    _capacity = bound(_capacity, _stakeAmount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);

    // Initial stake
    vm.prank(staker);
    pool.stake(_stakeAmount);

    // Warp to invalid unstake time
    vm.warp(block.timestamp + _timeSkip);

    vm.prank(staker);
    vm.expectRevert(QueryTypeStakingPool.QueryTypeStakingPool__StillInLockupPeriod.selector);
    pool.unstake(_unstakeAmount);
  }

  function testFuzz_RevertIf_NoStakeFound(address _nonStaker, uint256 _amount, uint256 _capacity)
    public
  {
    vm.assume(_nonStaker != address(0));
    vm.assume(_nonStaker != staker);
    _amount = bound(_amount, 1, INITIAL_BALANCE);
    _capacity = bound(_capacity, _amount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);

    vm.prank(_nonStaker);
    vm.expectRevert(QueryTypeStakingPool.QueryTypeStakingPool__NoStakeFound.selector);
    pool.unstake(_amount);
  }

  function testFuzz_RevertIf_InsufficientBalance(
    uint256 _stakeAmount,
    uint256 _unstakeAmount,
    uint256 _timeSkip,
    uint256 _capacity
  ) public {
    _stakeAmount = bound(_stakeAmount, 1, INITIAL_BALANCE);
    _unstakeAmount = bound(_unstakeAmount, _stakeAmount + 1, type(uint256).max);

    _timeSkip = bound(_timeSkip, pool.lockupPeriod() + 1, MAX_TIME_SKIP);
    _capacity = bound(_capacity, _stakeAmount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);

    // Initial stake
    vm.prank(staker);
    pool.stake(_stakeAmount);

    // Warp to valid unstake time
    vm.warp(block.timestamp + _timeSkip);

    vm.prank(staker);
    vm.expectRevert(QueryTypeStakingPool.QueryTypeStakingPool__InsufficientBalance.selector);
    pool.unstake(_unstakeAmount);
  }

  function testFuzz_EmitsUnstakeEvent(
    uint256 _stakeAmount,
    uint256 _unstakeAmount,
    uint256 _timeSkip,
    uint256 _capacity
  ) public {
    _stakeAmount = bound(_stakeAmount, 1, INITIAL_BALANCE);
    _unstakeAmount = bound(_unstakeAmount, 1, _stakeAmount);
    _timeSkip = bound(_timeSkip, pool.lockupPeriod() + 1, pool.lockupPeriod() + pool.accessPeriod());
    _capacity = bound(_capacity, _stakeAmount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);

    // Initial stake
    vm.prank(staker);
    pool.stake(_stakeAmount);

    // Warp to valid unstake time
    vm.warp(block.timestamp + _timeSkip);

    vm.expectEmit();
    emit QueryTypeStakingPool.Unstaked(staker, _unstakeAmount);

    vm.prank(staker);
    pool.unstake(_unstakeAmount);
  }

  function testFuzz_UnstakeBlockedUser(
    uint256 _stakeAmount,
    uint256 _unstakeAmount,
    uint256 _timeSkip,
    uint256 _capacity
  ) public {
    _stakeAmount = bound(_stakeAmount, 1, INITIAL_BALANCE);
    _unstakeAmount = bound(_unstakeAmount, 1, _stakeAmount);
    _timeSkip = bound(_timeSkip, pool.lockupPeriod() + 1, MAX_TIME_SKIP);
    _capacity = bound(_capacity, _stakeAmount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);

    // Initial stake
    vm.prank(staker);
    pool.stake(_stakeAmount);

    // Block the staker
    pool.blocklist(staker);

    // Warp to valid unstake time
    vm.warp(block.timestamp + _timeSkip);

    uint256 initialTotalJailed = pool.totalJailed();

    vm.prank(staker);
    pool.unstake(_unstakeAmount);

    assertEq(
      pool.totalJailed(),
      initialTotalJailed - _unstakeAmount,
      "Total jailed should decrease by unstake amount"
    );
    assertEq(pool.totalStaked(), 0, "Total staked should be zero after jailing");
  }
}

contract SetSigner is QueryTypeStakingPoolTest {
  function testFuzz_SetSignerSuccessfully(address _signer, uint256 _stakeAmount, uint256 _capacity)
    public
  {
    _stakeAmount = bound(_stakeAmount, 1, INITIAL_BALANCE);
    _capacity = bound(_capacity, _stakeAmount, type(uint256).max);

    // Setup initial stake
    pool.setStakingTokenCapacity(_capacity);
    vm.prank(staker);
    pool.stake(_stakeAmount);

    assertEq(pool.stakerSigners(staker), address(0));

    vm.prank(staker);
    pool.setSigner(_signer);
    assertEq(pool.stakerSigners(staker), _signer);
  }

  function testFuzz_EmitsSignerUpdatedEvent(
    address _oldSigner,
    address _newSigner,
    uint256 _stakeAmount,
    uint256 _capacity
  ) public {
    _stakeAmount = bound(_stakeAmount, 1, INITIAL_BALANCE);
    _capacity = bound(_capacity, _stakeAmount, type(uint256).max);

    // Setup initial stake
    pool.setStakingTokenCapacity(_capacity);
    vm.prank(staker);
    pool.stake(_stakeAmount);

    // Set initial signer
    vm.prank(staker);
    pool.setSigner(_oldSigner);

    vm.expectEmit();
    emit QueryTypeStakingPool.SignerUpdated(staker, _oldSigner, _newSigner);

    vm.prank(staker);
    pool.setSigner(_newSigner);
  }

  function testFuzz_RevertIf_NoStake(address _signer) public {
    vm.prank(staker);
    vm.expectRevert(QueryTypeStakingPool.QueryTypeStakingPool__NoStakeFound.selector);
    pool.setSigner(_signer);
  }
}

contract Blocklist is QueryTypeStakingPoolTest {
  function testFuzz_BlocklistUserSuccessfully(
    address _user,
    uint256 _stakeAmount,
    uint256 _capacity
  ) public {
    vm.assume(_user != address(0));
    _stakeAmount = bound(_stakeAmount, 1, INITIAL_BALANCE);
    _capacity = bound(_capacity, _stakeAmount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);

    // Setup stake for user
    stakingToken.mint(_user, _stakeAmount);
    vm.startPrank(_user);
    stakingToken.approve(address(pool), _stakeAmount);
    pool.stake(_stakeAmount);
    vm.stopPrank();

    // Blocklist user
    pool.blocklist(_user);

    assertTrue(pool.isBlocklisted(_user));
    assertEq(pool.totalJailed(), _stakeAmount);
    assertEq(pool.totalStaked(), 0);
  }

  function testFuzz_BlocklistEmitsEvents(address _user, uint256 _stakeAmount, uint256 _capacity)
    public
  {
    vm.assume(_user != address(0));
    _stakeAmount = bound(_stakeAmount, 1, INITIAL_BALANCE);
    _capacity = bound(_capacity, _stakeAmount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);

    // Setup stake for user
    stakingToken.mint(_user, _stakeAmount);
    vm.startPrank(_user);
    stakingToken.approve(address(pool), _stakeAmount);
    pool.stake(_stakeAmount);
    vm.stopPrank();

    vm.expectEmit();
    emit QueryTypeStakingPool.StakeJailed(_user, _stakeAmount);
    vm.expectEmit();
    emit QueryTypeStakingPool.AddressBlocklisted(_user);

    pool.blocklist(_user);
  }

  function testFuzz_RevertIf_BlocklistingAlreadyBlocklistedUser(
    address _user,
    uint256 _stakeAmount,
    uint256 _capacity
  ) public {
    vm.assume(_user != address(0));
    _stakeAmount = bound(_stakeAmount, 1, INITIAL_BALANCE);
    _capacity = bound(_capacity, _stakeAmount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);

    // Setup stake for user
    stakingToken.mint(_user, _stakeAmount);
    vm.startPrank(_user);
    stakingToken.approve(address(pool), _stakeAmount);
    pool.stake(_stakeAmount);
    vm.stopPrank();

    // First blocklist
    pool.blocklist(_user);

    // Try to blocklist again
    vm.expectRevert(QueryTypeStakingPool.QueryTypeStakingPool__AlreadyBlocklisted.selector);
    pool.blocklist(_user);
  }

  function testFuzz_BlocklistingUserWithNoStake(address _user) public {
    vm.assume(_user != address(0));

    // Blocklist user with no stake
    pool.blocklist(_user);

    assertTrue(pool.isBlocklisted(_user));
    assertEq(pool.totalJailed(), 0); // No tokens to jail
    assertEq(pool.totalStaked(), 0); // No tokens staked
  }

  function testFuzz_RevertIf_NotOwnerTriesToBlocklist(
    address _notOwner,
    address _user,
    uint256 _stakeAmount,
    uint256 _capacity
  ) public {
    vm.assume(_notOwner != address(this)); // not owner
    vm.assume(_user != address(0));
    _stakeAmount = bound(_stakeAmount, 1, INITIAL_BALANCE);
    _capacity = bound(_capacity, _stakeAmount, type(uint256).max);

    pool.setStakingTokenCapacity(_capacity);

    // Setup stake for user
    stakingToken.mint(_user, _stakeAmount);
    vm.startPrank(_user);
    stakingToken.approve(address(pool), _stakeAmount);
    pool.stake(_stakeAmount);
    vm.stopPrank();

    vm.prank(_notOwner);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _notOwner));
    pool.blocklist(_user);
  }
}
