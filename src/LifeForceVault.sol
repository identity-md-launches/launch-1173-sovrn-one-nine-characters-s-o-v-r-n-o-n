// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SovrnToken} from "./SovrnToken.sol";
import {Guard} from "./Interfaces.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @notice ETH accounting for inference and manual buybacks. Only the fixed Safe can withdraw.
contract LifeForceVault is Guard {
    address public constant REFUEL_SAFE = 0xb1eC9d1C36974d05eb9889eBf8A150b05791E559;
    uint256 public constant INFERENCE_BPS = 7000;
    uint256 public constant BUYBACK_BPS = 3000;
    SovrnToken public immutable token;
    address public immutable hook;
    uint256 private inference;
    uint256 private buyback;

    event LifeForceFunded(address indexed from, uint256 amount, uint256 inference, uint256 buyback);
    event InferenceWithdrawn(uint256 amount);
    event BuybackWithdrawn(uint256 amount);
    event Burned(uint256 amount);
    error Unauthorized();
    error InvalidAmount();

    constructor(IPoolManager manager_, SovrnToken token_, address hook_) {
        // The hook is still under construction, so it cannot have runtime code yet.
        if (address(manager_).code.length == 0 || address(token_).code.length == 0 || hook_ == address(0)) {
            revert Unauthorized();
        }
        token = token_;
        hook = hook_;
    }

    modifier onlySafe() {
        if (msg.sender != REFUEL_SAFE) revert Unauthorized();
        _;
    }

    receive() external payable {
        uint256 forBuyback = _buybackShare(msg.value);
        uint256 forInference = msg.value - forBuyback;
        inference += forInference;
        buyback += forBuyback;
        emit LifeForceFunded(msg.sender, msg.value, forInference, forBuyback);
    }

    function inferenceReserve() public view returns (uint256 amount) {
        (amount,) = _reserves();
    }

    function buybackReserve() public view returns (uint256 amount) {
        (, amount) = _reserves();
    }

    function sovrnHeld() public view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function withdrawInference(uint256 amount) external onlySafe nonReentrant {
        (inference, buyback) = _reserves();
        if (amount > inference) revert InvalidAmount();
        inference -= amount;
        _sendETH(REFUEL_SAFE, amount);
        emit InferenceWithdrawn(amount);
    }

    function withdrawBuyback(uint256 amount) external onlySafe nonReentrant {
        (inference, buyback) = _reserves();
        if (amount > buyback) revert InvalidAmount();
        buyback -= amount;
        _sendETH(REFUEL_SAFE, amount);
        emit BuybackWithdrawn(amount);
    }

    function burn() external {
        uint256 amount = sovrnHeld();
        if (amount == 0) revert InvalidAmount();
        // The immutable launch token has plain transfers and no callbacks.
        if (!token.transfer(token.DEAD(), amount)) revert InvalidAmount();
        emit Burned(amount);
    }

    /// @dev Include ETH delivered without receive(), including prefunding. Such ETH cannot be
    ///      refused by an EVM contract; account for it in both views and checkpoint on withdrawal.
    function _reserves() private view returns (uint256, uint256) {
        uint256 extra = address(this).balance - inference - buyback;
        uint256 extraBuyback = _buybackShare(extra);
        return (inference + extra - extraBuyback, buyback + extraBuyback);
    }

    function _buybackShare(uint256 amount) private pure returns (uint256) {
        // Exactly floor(amount * 3000 / 10000), without an overflowing intermediate product.
        return (amount / 10_000) * BUYBACK_BPS + (amount % 10_000) * BUYBACK_BPS / 10_000;
    }
}
