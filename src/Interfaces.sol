// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

abstract contract Guard {
    uint256 private entered;
    error Reentrancy();
    modifier nonReentrant() {
        if (entered != 0) revert Reentrancy();
        entered = 1;
        _;
        entered = 0;
    }
    error ETHSendFailed();

    function _sendETH(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert ETHSendFailed();
    }
}
