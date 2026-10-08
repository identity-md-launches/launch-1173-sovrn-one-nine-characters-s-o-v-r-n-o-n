// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Fixed launch supply. Burning is an ordinary transfer to DEAD, never a supply reduction.
contract SovrnToken {
    string public constant name = "SOVRN.ONE";
    string public constant symbol = "SVO";
    uint8 public constant decimals = 18;
    uint256 public constant totalSupply = 1_000_000_000 ether;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalBurned;
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    error ZeroAddress();

    constructor() {
        balanceOf[msg.sender] = totalSupply;
        emit Transfer(address(0), msg.sender, totalSupply);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 approved = allowance[from][msg.sender];
        if (approved != type(uint256).max) allowance[from][msg.sender] = approved - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        if (to == DEAD) totalBurned += amount;
        emit Transfer(from, to, amount);
    }
}
