// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {QueryTypeStakerFactory} from "src/QueryTypeStakerFactory.sol";
import {QueryTypeStakingPool} from "src/QueryTypeStakingPool.sol";
import {VmSafe} from "forge-std/Vm.sol";

contract QueryTypeStakerFactoryTest is Test {
  QueryTypeStakerFactory public factory;
  address public owner;
  uint8 public queryType;

  function setUp() public virtual {
    owner = makeAddr("owner");
    vm.prank(owner);
    factory = new QueryTypeStakerFactory(owner);
    queryType = 1;
  }

  function _createPool() internal returns (address) {
    vm.prank(owner);
    return factory.createStakingPool(queryType);
  }
}

contract Constructor is QueryTypeStakerFactoryTest {
  function testFuzz_SetsOwnerCorrectly(address _owner) public {
    vm.assume(_owner != address(0));
    vm.prank(_owner);
    QueryTypeStakerFactory newFactory = new QueryTypeStakerFactory(_owner);
    assertEq(newFactory.owner(), _owner);
  }
}

contract CreateStakingPool is QueryTypeStakerFactoryTest {
  function testFuzz_CreatesNewStakingPoolWithArbitraryQueryType(uint8 _queryType) public {
    vm.prank(owner);
    address poolAddress = factory.createStakingPool(_queryType);

    assertTrue(poolAddress != address(0));
    assertEq(factory.queryTypePools(_queryType), poolAddress);
  }

  function testFuzz_EmitsCreateQueryTypeStakingPoolEventWithArbitraryQueryType(uint8 _queryType)
    public
  {
    vm.recordLogs();
    vm.prank(owner);
    address poolAddress = factory.createStakingPool(_queryType);

    VmSafe.Log[] memory entries = vm.getRecordedLogs();
    assertEq(entries.length, 1);
    assertEq(entries[0].topics[0], keccak256("CreateQueryTypeStakingPool(uint8,address)"));
    assertEq(entries[0].topics[1], bytes32(uint256(_queryType))); // queryType
    assertEq(entries[0].topics[2], bytes32(uint256(uint160(poolAddress)))); // poolAddress
  }

  function testFuzz_RevertIf_CallerIsNotOwner(address notOwner) public {
    vm.assume(notOwner != owner && notOwner != address(0));

    vm.prank(notOwner);
    vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", notOwner));
    factory.createStakingPool(queryType);
  }

  function testFuzz_RevertIf_PoolAlreadyExistsWithArbitraryQueryType(uint8 _queryType) public {
    vm.startPrank(owner);
    factory.createStakingPool(_queryType);

    vm.expectRevert(QueryTypeStakerFactory.QueryTypeStakerFactory__PoolExists.selector);
    factory.createStakingPool(_queryType);
    vm.stopPrank();
  }
}
