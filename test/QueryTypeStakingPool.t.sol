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
  function testFuzz_StakesTokensSuccessfully(uint256 _amount, bytes32 _conversionEntry) public {
    _amount = bound(_amount, 1, INITIAL_BALANCE);

    pool.updateConversionTable(_conversionEntry);
    uint256 expectedIndex = pool.getConversionTableHistoryLength() - 1;

    uint256 expectedLockupEnd = block.timestamp + pool.LOCKUP_PERIOD();
    uint256 expectedAccessEnd = expectedLockupEnd + pool.ACCESS_PERIOD();

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

  function testFuzz_EmitsStakeEvent(uint256 _amount, bytes32 _conversionEntry) public {
    _amount = bound(_amount, 1, INITIAL_BALANCE);

    pool.updateConversionTable(_conversionEntry);
    uint256 expectedIndex = pool.getConversionTableHistoryLength() - 1;

    uint48 expectedLockupEnd = uint48(block.timestamp) + pool.LOCKUP_PERIOD();
    uint48 expectedAccessEnd = expectedLockupEnd + pool.ACCESS_PERIOD();

    vm.expectEmit();
    emit QueryTypeStakingPool.Staked(
      staker, _amount, expectedIndex, expectedLockupEnd, expectedAccessEnd
    );

    vm.prank(staker);
    pool.stake(_amount);
  }

  function testFuzz_RevertIf_AmountIsZero() public {
    vm.prank(staker);
    vm.expectRevert(QueryTypeStakingPool.QueryTypeStakingPool__AmountTooLow.selector);
    pool.stake(0);
  }

  function testFuzz_RevertIf_InsufficientBalance(uint256 _amount) public {
    _amount = bound(_amount, INITIAL_BALANCE + 1, type(uint256).max);

    vm.prank(staker);
    vm.expectRevert(
      abi.encodeWithSignature(
        "ERC20InsufficientBalance(address,uint256,uint256)", staker, INITIAL_BALANCE, _amount
      )
    );
    pool.stake(_amount);
  }

  function testFuzz_RevertIf_TokenTransferFails(uint256 _amount) public {
    _amount = bound(_amount, 1, INITIAL_BALANCE);

    stakingToken.setTransferFromShouldFail(true);

    vm.prank(staker);
    vm.expectRevert(
      abi.encodeWithSelector(
        bytes4(keccak256("SafeERC20FailedOperation(address)")), address(stakingToken)
      )
    );
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
