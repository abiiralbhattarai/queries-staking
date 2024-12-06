// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {QueryTypeStakingPool} from "src/QueryTypeStakingPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract QueryTypeStakingPoolTest is Test {
  QueryTypeStakingPool public pool;
  MockERC20 public stakingToken;
  address public staker;
  uint256 public constant INITIAL_BALANCE = 1000 ether;

  function setUp() public virtual {
    staker = makeAddr("staker");
    stakingToken = new MockERC20();
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
    vm.assume(_notOwner != address(this));
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
