// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SovrnToken} from "./SovrnToken.sol";
import {Guard} from "./Interfaces.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @notice IMD accounting for inference and manual buybacks. Only the fixed Safe can withdraw.
/// @dev IMD is an ERC-20, so the vault cannot react to deposits: reserves are derived from its IMD balance.
///      Reserves never sum to more than the balance actually held (a shortfall reduces buyback first).
contract LifeForceVault is Guard {
    address public constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address public constant REFUEL_SAFE = 0xEb57c52272B90F989C41B739e2ccc5f00bF7697C;
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
    error TransferFailed();

    constructor(IPoolManager manager_, SovrnToken token_, address hook_) {
        // The hook is still under construction, so it cannot have runtime code yet.
        if (
            address(manager_).code.length == 0 || address(token_).code.length == 0 || IMD.code.length == 0
                || hook_ == address(0)
        ) {
            revert Unauthorized();
        }
        token = token_;
        hook = hook_;
    }

    modifier onlySafe() {
        if (msg.sender != REFUEL_SAFE) revert Unauthorized();
        _;
    }

    function imd() external pure returns (address) {
        return IMD;
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

    /// @notice Anyone may checkpoint IMD that arrived since the last checkpoint. Views already include it.
    function sync() external nonReentrant {
        uint256 tracked = inference + buyback;
        (uint256 newInference, uint256 newBuyback) = _reserves();
        uint256 seen = newInference + newBuyback;
        inference = newInference;
        buyback = newBuyback;
        if (seen > tracked) {
            uint256 added = seen - tracked;
            uint256 addedBuyback = _buybackShare(added);
            emit LifeForceFunded(address(0), added, added - addedBuyback, addedBuyback);
        }
    }

    function withdrawInference(uint256 amount) external onlySafe nonReentrant {
        (inference, buyback) = _reserves();
        if (amount > inference) revert InvalidAmount();
        inference -= amount;
        _sendIMD(REFUEL_SAFE, amount);
        emit InferenceWithdrawn(amount);
    }

    function withdrawBuyback(uint256 amount) external onlySafe nonReentrant {
        (inference, buyback) = _reserves();
        if (amount > buyback) revert InvalidAmount();
        buyback -= amount;
        _sendIMD(REFUEL_SAFE, amount);
        emit BuybackWithdrawn(amount);
    }

    function burn() external {
        uint256 amount = sovrnHeld();
        if (amount == 0) revert InvalidAmount();
        // The immutable launch token has plain transfers and no callbacks.
        if (!token.transfer(token.DEAD(), amount)) revert InvalidAmount();
        emit Burned(amount);
    }

    /// @dev Reserves = checkpointed reserves + any untracked IMD (split 70/30), clamped to the real balance.
    ///      Inference keeps priority: a shortfall (an IMD transfer fee, a seizure) comes out of buyback first.
    function _reserves() private view returns (uint256 inferenceOut, uint256 buybackOut) {
        uint256 balance = _imdBalance();
        uint256 tracked = inference + buyback;
        if (balance >= tracked) {
            uint256 extra = balance - tracked;
            uint256 extraBuyback = _buybackShare(extra);
            return (inference + extra - extraBuyback, buyback + extraBuyback);
        }
        inferenceOut = inference > balance ? balance : inference;
        buybackOut = balance - inferenceOut;
        if (buybackOut > buyback) buybackOut = buyback;
    }

    function _buybackShare(uint256 amount) private pure returns (uint256) {
        // Exactly floor(amount * 3000 / 10000), without an overflowing intermediate product.
        return (amount / 10_000) * BUYBACK_BPS + (amount % 10_000) * BUYBACK_BPS / 10_000;
    }

    function _imdBalance() private view returns (uint256) {
        (bool ok, bytes memory data) = IMD.staticcall(abi.encodeWithSignature("balanceOf(address)", address(this)));
        if (!ok || data.length < 32) revert TransferFailed();
        return abi.decode(data, (uint256));
    }

    function _sendIMD(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok, bytes memory data) = IMD.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
