// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {ERC20} from "solmate/src/tokens/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s, uint256 supply) ERC20(n, s, 18) {
        _mint(msg.sender, supply);
    }
}

/// @dev ERC-777 style hook: MockIMD calls this on the configured callback target after a transfer to it.
interface IIMDReceiver {
    function tokensReceived(uint256 amount) external;
}

/// @dev Stand-in for IMD at its real address. Plain ERC-20 unless a test flips a switch, to model the
///      misbehaviour a real token could show (refusing a recipient, a transfer fee, a false return).
contract MockIMD is ERC20 {
    mapping(address => bool) public refuses; // transfers TO these addresses revert
    bool public returnFalse; // transfer/transferFrom return false instead of moving funds
    uint256 public feeBps; // transfer fee, burned from the amount
    address public callbackTarget; // if set (and a contract), it is called after a transfer TO it (re-entry model)

    constructor(uint256 supply) ERC20("Identity.md", "IMD", 18) {
        _mint(msg.sender, supply);
    }

    function setRefuses(address who, bool v) external {
        refuses[who] = v;
    }

    function setReturnFalse(bool v) external {
        returnFalse = v;
    }

    function setFeeBps(uint256 v) external {
        feeBps = v;
    }

    function setCallback(address who) external {
        callbackTarget = who;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (refuses[to]) revert("refused");
        if (returnFalse) return false;
        balanceOf[msg.sender] -= amount;
        uint256 fee = amount * feeBps / 10_000;
        unchecked { balanceOf[to] += amount - fee; }
        totalSupply -= fee;
        emit Transfer(msg.sender, to, amount - fee);
        if (to == callbackTarget && to.code.length > 0) IIMDReceiver(to).tokensReceived(amount - fee);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (refuses[to]) revert("refused");
        if (returnFalse) return false;
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        uint256 fee = amount * feeBps / 10_000;
        unchecked { balanceOf[to] += amount - fee; }
        totalSupply -= fee;
        emit Transfer(from, to, amount - fee);
        if (to == callbackTarget && to.code.length > 0) IIMDReceiver(to).tokensReceived(amount - fee);
        return true;
    }
}
