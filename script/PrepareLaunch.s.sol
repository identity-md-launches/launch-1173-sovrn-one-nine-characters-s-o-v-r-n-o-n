// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {SovrnHook} from "../src/SovrnHook.sol";
import {SovrnToken} from "../src/SovrnToken.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @notice Offline preparation helper. No broadcasts, environment variables, signing, or admin keys.
/// @dev The launch factory supplies its manager and the token it just deployed. Constructor creates
///      the immutable LifeForceVault automatically; there are no post-launch configuration transactions.
contract PrepareLaunch {
    function initCode(IPoolManager manager, SovrnToken token, address factory) public pure returns (bytes memory) {
        return abi.encodePacked(type(SovrnHook).creationCode, abi.encode(manager, token, factory));
    }

    function predict(address create2Deployer, bytes32 salt, bytes32 initCodeHash) public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), create2Deployer, salt, initCodeHash)))));
    }

    /// @notice Search a bounded interval; continue at firstSalt + attempts if none matched.
    function mine(address create2Deployer, bytes32 initCodeHash, uint256 firstSalt, uint256 attempts)
        external
        pure
        returns (bool found, bytes32 salt, address predicted)
    {
        for (uint256 i; i < attempts; ++i) {
            salt = bytes32(firstSalt + i);
            predicted = predict(create2Deployer, salt, initCodeHash);
            if (HookFlags.matches(predicted, HookFlags.SOVRN_FLAGS)) return (true, salt, predicted);
        }
    }
}
