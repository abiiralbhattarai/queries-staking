// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {QueryTypeStakingPool} from "src/QueryTypeStakingPool.sol";

/// @title QueryTypeStakerFactory
/// @author [ScopeLift](https://scopelift.co)
/// @notice This contract manages the creation of staking pools for different query types.
/// Each query type can have one active staking pool, and only the contract owner can create new
/// pools.
contract QueryTypeStakerFactory is Ownable {
  /// @notice Maps query types to their corresponding staking pool addresses
  mapping(uint8 queryType => address poolAddress) public queryTypePools;

  /// @notice Emitted when a new staking pool is created for a query type
  event CreateQueryTypeStakingPool(uint8 indexed queryType, address indexed poolAddress);

  /// @notice Thrown when attempting to create a pool for a query type that already has one
  error QueryTypeStakerFactory__PoolExists();

  /// @notice Constructor that sets the initial owner
  constructor(address _owner) Ownable(_owner) {}

  /// @notice Creates a new staking pool for a specific query type
  /// @param _queryType The type of query this pool will be associated with
  /// @return _poolAddress The address of the newly created staking pool
  /// @dev Only callable by the contract owner
  function createStakingPool(uint8 _queryType) external onlyOwner returns (address _poolAddress) {
    if (queryTypePools[_queryType] != address(0)) revert QueryTypeStakerFactory__PoolExists();

    // Deploy new staking pool
    QueryTypeStakingPool _newPool = new QueryTypeStakingPool();
    _poolAddress = address(_newPool);

    // Store the pool address
    queryTypePools[_queryType] = _poolAddress;

    emit CreateQueryTypeStakingPool(_queryType, _poolAddress);
  }
}
