// SPDX-License-Identifier: MIT
pragma solidity >=0.4.22 <0.9.0;
import '../UniswapV2ERC20.sol';

contract ERC20 is UniswapV2ERC20 {
    constructor(uint _totalSupply) public {
        _mint(msg.sender, _totalSupply);
    }
}
