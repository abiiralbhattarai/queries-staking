// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
  constructor() ERC20("Mock Token", "MOCK") {}

  function mint(address to, uint256 amount) external {
    _mint(to, amount);
  }

  bool public transferFromShouldFail;

  function setTransferFromShouldFail(bool _shouldFail) external {
    transferFromShouldFail = _shouldFail;
  }

  function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
    if (transferFromShouldFail) return false;
    return super.transferFrom(from, to, amount);
  }

  error SafeERC20FailedOperation(address token);

  bool public transferShouldFail = false;

  function setTransferShouldFail(bool _shouldFail) external {
    transferShouldFail = _shouldFail;
  }

  function transfer(address to, uint256 amount) public override returns (bool) {
    if (transferShouldFail) revert SafeERC20FailedOperation(address(this));
    return super.transfer(to, amount);
  }
}
