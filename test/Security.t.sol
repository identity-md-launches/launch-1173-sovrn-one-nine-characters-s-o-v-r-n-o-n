// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SystemBase} from "./SystemBase.sol";
import {SovrnHook} from "../src/SovrnHook.sol";
import {SovrnToken} from "../src/SovrnToken.sol";
import {LifeForceVault} from "../src/LifeForceVault.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {RejectETH} from "./Hook.t.sol";

contract HookReentryProbe {
    SovrnHook private immutable hook;
    bool public succeeded;
    bytes public reason;

    constructor(SovrnHook h) {
        hook = h;
    }

    receive() external payable {
        (succeeded, reason) = address(hook).call(abi.encodeCall(hook.redeemFees, ()));
    }
}

contract SecurityTest is SystemBase {
    function setUp() public {
        _system(true);
    }

    function test_exactPermissionsAndFlags() public view {
        Hooks.Permissions memory expected;
        expected.beforeInitialize = true;
        expected.beforeSwap = true;
        expected.afterSwap = true;
        expected.beforeSwapReturnDelta = true;
        expected.afterSwapReturnDelta = true;
        assertEq(abi.encode(hook.getHookPermissions()), abi.encode(expected));
        assertEq(HookFlags.SOVRN_FLAGS, 8396);
        assertEq(HookFlags.flagsOf(address(hook)), 8396);
        assertEq(abi.encode(hook.poolKey()), abi.encode(key));
    }

    function test_firstInitEveryFieldAndSecondInitRejected() public {
        address at = address(uint160(0xa0cc));
        deployCodeTo("SovrnHook.sol:SovrnHook", abi.encode(manager, token, address(this)), at);
        SovrnHook fresh = SovrnHook(payable(at));
        PoolKey memory correct = key;
        correct.hooks = IHooks(at);
        assertEq(fresh.launchFeeNow(), 0.5e18);
        assertEq(fresh.decayMinutesLeft(), 60);
        vm.prank(address(manager));
        vm.expectRevert(SovrnHook.WrongPool.selector);
        fresh.beforeSwap(address(router), correct, SwapParams(true, -1, START_PRICE / 2), "");
        for (uint256 i; i < 7; ++i) {
            PoolKey memory bad = abi.decode(abi.encode(correct), (PoolKey));
            if (i == 0) bad.currency0 = Currency.wrap(ALICE);
            if (i == 1) bad.currency1 = Currency.wrap(ALICE);
            if (i == 2) bad.fee = 3000;
            if (i == 3) bad.tickSpacing = 0;
            if (i == 4) bad.tickSpacing = -60;
            if (i == 5) bad.hooks = IHooks(ALICE);
            vm.prank(address(manager));
            vm.expectRevert(SovrnHook.WrongPool.selector);
            fresh.beforeInitialize(i == 6 ? ALICE : address(this), bad, START_PRICE);
            assertFalse(fresh.initialized());
        }
        manager.initialize(correct, START_PRICE);
        assertTrue(fresh.initialized());
        vm.prank(address(manager));
        vm.expectRevert(SovrnHook.WrongPool.selector);
        fresh.beforeInitialize(address(this), correct, START_PRICE);
    }

    function test_constructorCodeChecksAndInvalidFlags() public {
        vm.expectRevert(SovrnHook.Unauthorized.selector);
        new SovrnHook(IPoolManager(ALICE), token, address(this));
        vm.expectRevert(SovrnHook.Unauthorized.selector);
        new SovrnHook(manager, SovrnToken(ALICE), address(this));
        vm.expectRevert(SovrnHook.Unauthorized.selector);
        new SovrnHook(manager, token, address(0));
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        assertFalse(HookFlags.matches(predicted, HookFlags.SOVRN_FLAGS));
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new SovrnHook(manager, token, address(this));
        vm.expectRevert(LifeForceVault.Unauthorized.selector);
        new LifeForceVault(IPoolManager(ALICE), token, address(hook));
        vm.expectRevert(LifeForceVault.Unauthorized.selector);
        new LifeForceVault(manager, SovrnToken(ALICE), address(hook));
        vm.expectRevert(LifeForceVault.Unauthorized.selector);
        new LifeForceVault(manager, token, address(0));
    }

    function test_directFeeRejectionRollsBackSwapAndBusyGuard() public {
        bytes memory original = address(vault).code;
        vm.etch(address(vault), address(new RejectETH()).code);
        uint256 oldETH = address(manager).balance;
        uint256 oldTokens = token.balanceOf(address(this));
        vm.expectRevert();
        _trade(true, -1 ether);
        assertEq(address(manager).balance, oldETH);
        assertEq(token.balanceOf(address(this)), oldTokens);
        assertEq(hook.claimFees(), 0);
        vm.etch(address(vault), original);
        _trade(true, -1 ether);
        assertEq(address(vault).balance, 0.5 ether);
    }

    function test_feeCallbackCannotReenterRedemption() public {
        vm.etch(address(vault), address(new HookReentryProbe(hook)).code);
        _trade(true, -1 ether);
        HookReentryProbe probe = HookReentryProbe(payable(address(vault)));
        assertFalse(probe.succeeded());
        assertEq(probe.reason(), abi.encodeWithSelector(SovrnHook.Busy.selector));
        assertEq(address(vault).balance, 0.5 ether);
    }

    function test_noAdministrationEvenForFactoryOrSafe() public {
        string[8] memory signatures = [
            "owner()",
            "transferOwnership(address)",
            "setOwner(address)",
            "upgradeTo(address)",
            "pause()",
            "setVault(address)",
            "setFee(uint256)",
            "setSafe(address)"
        ];
        address[3] memory targets = [address(token), address(hook), address(vault)];
        address[3] memory callers = [address(this), vault.REFUEL_SAFE(), ALICE];
        for (uint256 i; i < targets.length; ++i) {
            for (uint256 j; j < signatures.length; ++j) {
                for (uint256 k; k < callers.length; ++k) {
                    vm.prank(callers[k]);
                    (bool ok,) = targets[i].call(abi.encodeWithSignature(signatures[j], ALICE));
                    assertFalse(ok, signatures[j]);
                }
            }
        }
    }

    function test_runtimeHasNoEscapeOpcodes() public view {
        _scan(address(token));
        _scan(address(hook));
        _scan(address(vault));
    }

    function _scan(address target) private view {
        bytes memory code = target.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
        }
    }
}
