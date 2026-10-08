// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {PrepareLaunch} from "../script/PrepareLaunch.s.sol";
import {SovrnToken} from "../src/SovrnToken.sol";
import {SovrnHook} from "../src/SovrnHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

contract LaunchFactoryHarness {
    function deployToken() external returns (SovrnToken) {
        return new SovrnToken();
    }

    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") { deployed := create2(0, add(code, 32), mload(code), salt) }
        require(deployed != address(0));
    }

    function initialize(IPoolManager manager, PoolKey memory key, uint160 price) external {
        manager.initialize(key, price);
    }
}

contract LaunchTest is Test {
    using StateLibrary for IPoolManager;
    uint160 private constant INITIAL_PRICE = 792281625142643375935439503360000;

    function test_realCreate2DeploymentInitializesAllContracts() public {
        PoolManager manager = new PoolManager(address(this));
        LaunchFactoryHarness factory = new LaunchFactoryHarness();
        SovrnToken token = factory.deployToken();
        PrepareLaunch p = new PrepareLaunch();
        bytes memory code = p.initCode(manager, token, address(factory));
        (bool found, bytes32 salt, address expected) = p.mine(address(factory), keccak256(code), 0, 200000);
        assertTrue(found);
        assertTrue(HookFlags.matches(expected, HookFlags.SOVRN_FLAGS));
        SovrnHook hook = SovrnHook(payable(factory.deploy(code, salt)));
        assertEq(address(hook), expected);
        assertEq(token.balanceOf(address(factory)), 1e27);
        assertGt(address(hook.vault()).code.length, 0);
        assertEq(hook.vault().hook(), expected);
        assertEq(address(hook.vault().token()), address(token));
        PoolKey memory key =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 12500, 60, IHooks(expected));
        vm.expectRevert();
        manager.initialize(key, INITIAL_PRICE);
        factory.initialize(manager, key, INITIAL_PRICE);
        (uint160 actualPrice,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(actualPrice, INITIAL_PRICE);
        uint256 rootRatio = uint256(actualPrice) / (1 << 96);
        assertEq(rootRatio * rootRatio, 100_000_000);
        assertEq(token.totalSupply() / (rootRatio * rootRatio), 10 ether);
        assertTrue(hook.initialized());
        assertEq(hook.launchFeeNow(), 0.5e18);
        vm.expectRevert();
        factory.initialize(manager, key, INITIAL_PRICE);
        assertLe(expected.code.length, 24576);
        assertLe(address(hook.vault()).code.length, 24576);
        assertLe(code.length, 49152);
    }
}
