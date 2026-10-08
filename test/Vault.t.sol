// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SystemBase} from "./SystemBase.sol";
import {LifeForceVault} from "../src/LifeForceVault.sol";
import {Guard} from "../src/Interfaces.sol";
import {RejectETH} from "./Hook.t.sol";

contract SafeReentryProbe {
    LifeForceVault private immutable vault;
    bool public inferenceOK;
    bool public buybackOK;
    bytes public inferenceError;
    bytes public buybackError;

    constructor(LifeForceVault v) {
        vault = v;
    }

    receive() external payable {
        (inferenceOK, inferenceError) = address(vault).call(abi.encodeCall(vault.withdrawInference, (1)));
        (buybackOK, buybackError) = address(vault).call(abi.encodeCall(vault.withdrawBuyback, (1)));
        require(address(vault).balance == vault.inferenceReserve() + vault.buybackReserve(), "callback accounting");
    }
}

contract ForceETH {
    constructor(address payable to) payable {
        selfdestruct(to);
    }
}

contract VaultTest is SystemBase {
    event LifeForceFunded(address indexed from, uint256 amount, uint256 inference, uint256 buyback);
    event InferenceWithdrawn(uint256 amount);
    event BuybackWithdrawn(uint256 amount);
    event Burned(uint256 amount);

    function setUp() public {
        _system(false);
    }

    function _fund(uint256 amount) private {
        (bool ok,) = address(vault).call{value: amount}("");
        assertTrue(ok);
    }

    function test_splitRoundingAndEvents() public {
        assertEq(vault.REFUEL_SAFE(), 0xb1eC9d1C36974d05eb9889eBf8A150b05791E559);
        assertEq(vault.INFERENCE_BPS(), 7000);
        assertEq(vault.BUYBACK_BPS(), 3000);
        for (uint256 i; i <= 11; ++i) {
            uint256 beforeInference = vault.inferenceReserve();
            uint256 beforeBuyback = vault.buybackReserve();
            vm.expectEmit(true, false, false, true, address(vault));
            emit LifeForceFunded(address(this), i, i - i * 3 / 10, i * 3 / 10);
            _fund(i);
            assertEq(vault.inferenceReserve() - beforeInference, i - i * 3 / 10);
            assertEq(vault.buybackReserve() - beforeBuyback, i * 3 / 10);
            assertEq(address(vault).balance, vault.inferenceReserve() + vault.buybackReserve());
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_fundWithdrawRoundtrip(uint96 raw, bool inferenceFirst) public {
        uint256 amount = bound(raw, 0, 1000 ether);
        _fund(amount);
        uint256 safeBefore = vault.REFUEL_SAFE().balance;
        uint256 a = vault.inferenceReserve();
        uint256 b = vault.buybackReserve();
        assertEq(b, amount * 3 / 10);
        assertEq(a + b, amount);
        vm.startPrank(vault.REFUEL_SAFE());
        if (inferenceFirst) {
            vm.expectEmit(false, false, false, true, address(vault));
            emit InferenceWithdrawn(a);
            vault.withdrawInference(a);
            assertEq(vault.buybackReserve(), b);
            vault.withdrawBuyback(b);
        } else {
            vm.expectEmit(false, false, false, true, address(vault));
            emit BuybackWithdrawn(b);
            vault.withdrawBuyback(b);
            assertEq(vault.inferenceReserve(), a);
            vault.withdrawInference(a);
        }
        vm.stopPrank();
        assertEq(vault.REFUEL_SAFE().balance - safeBefore, amount);
        assertEq(address(vault).balance, 0);
        assertEq(vault.inferenceReserve() + vault.buybackReserve(), 0);
    }

    function test_onlySafeAndMatchingReserve() public {
        _fund(10 ether);
        address[4] memory callers = [ALICE, address(this), address(hook), address(manager)];
        for (uint256 i; i < callers.length; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(LifeForceVault.Unauthorized.selector);
            vault.withdrawInference(1);
            vm.expectRevert(LifeForceVault.Unauthorized.selector);
            vault.withdrawBuyback(1);
            vm.stopPrank();
        }
        vm.startPrank(vault.REFUEL_SAFE());
        vm.expectRevert(LifeForceVault.InvalidAmount.selector);
        vault.withdrawInference(7 ether + 1);
        vm.expectRevert(LifeForceVault.InvalidAmount.selector);
        vault.withdrawBuyback(3 ether + 1);
        vault.withdrawBuyback(3 ether);
        vm.expectRevert(LifeForceVault.InvalidAmount.selector);
        vault.withdrawBuyback(1);
        assertEq(vault.inferenceReserve(), 7 ether);
        vault.withdrawInference(7 ether);
        vm.expectRevert(LifeForceVault.InvalidAmount.selector);
        vault.withdrawInference(1);
        vm.stopPrank();
    }

    function test_rejectingSafeRollsBackBothWithdrawalsAndCanRetry() public {
        _fund(10 ether);
        address safe = vault.REFUEL_SAFE();
        vm.etch(safe, address(new RejectETH()).code);
        vm.startPrank(safe);
        vm.expectRevert(Guard.ETHSendFailed.selector);
        vault.withdrawInference(7 ether);
        vm.expectRevert(Guard.ETHSendFailed.selector);
        vault.withdrawBuyback(3 ether);
        vm.stopPrank();
        assertEq(vault.inferenceReserve(), 7 ether);
        assertEq(vault.buybackReserve(), 3 ether);
        assertEq(address(vault).balance, 10 ether);
        vm.etch(safe, hex"");
        vm.startPrank(safe);
        vault.withdrawInference(7 ether);
        vault.withdrawBuyback(3 ether);
        vm.stopPrank();
        assertEq(address(vault).balance, 0);
    }

    function testFuzz_sameAndCrossWithdrawalReentryBlocked(bool inferenceFirst) public {
        _fund(10 ether);
        address safe = vault.REFUEL_SAFE();
        vm.etch(safe, address(new SafeReentryProbe(vault)).code);
        vm.prank(safe);
        if (inferenceFirst) vault.withdrawInference(1 ether);
        else vault.withdrawBuyback(1 ether);
        SafeReentryProbe probe = SafeReentryProbe(payable(safe));
        assertFalse(probe.inferenceOK());
        assertFalse(probe.buybackOK());
        assertEq(probe.inferenceError(), abi.encodeWithSelector(Guard.Reentrancy.selector));
        assertEq(probe.buybackError(), abi.encodeWithSelector(Guard.Reentrancy.selector));
        assertEq(address(vault).balance, 9 ether);
        assertEq(vault.inferenceReserve(), inferenceFirst ? 6 ether : 7 ether);
        assertEq(vault.buybackReserve(), inferenceFirst ? 3 ether : 2 ether);
    }

    function test_burnEntireBalanceToDeadWithoutETHMovement() public {
        _fund(10 ether);
        vm.expectRevert(LifeForceVault.InvalidAmount.selector);
        vault.burn();
        token.transfer(address(vault), 123 ether);
        vm.prank(ALICE);
        token.transfer(address(vault), 7 ether);
        assertEq(vault.sovrnHeld(), 130 ether);
        vm.expectEmit(false, false, false, true, address(vault));
        emit Burned(130 ether);
        vm.prank(BOB);
        vault.burn();
        assertEq(vault.sovrnHeld(), 0);
        assertEq(token.balanceOf(token.DEAD()), 130 ether);
        assertEq(token.totalBurned(), 130 ether);
        assertEq(token.totalSupply(), 1e27);
        assertEq(address(vault).balance, 10 ether);
        assertEq(vault.inferenceReserve(), 7 ether);
        assertEq(vault.buybackReserve(), 3 ether);
        vm.expectRevert(LifeForceVault.InvalidAmount.selector);
        vault.burn();
    }

    function test_noTokenRescueApprovalOrAlternateDestinationEvenForSafe() public {
        token.transfer(address(vault), 1 ether);
        string[6] memory signatures = [
            "transfer(address,uint256)",
            "approve(address,uint256)",
            "withdrawToken(address,uint256)",
            "rescueToken(address,uint256)",
            "burn(address)",
            "setSafe(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            vm.prank(vault.REFUEL_SAFE());
            (bool ok,) = address(vault).call(abi.encodeWithSignature(signatures[i], ALICE, 1 ether));
            assertFalse(ok);
        }
        assertEq(vault.sovrnHeld(), 1 ether);
        assertEq(token.allowance(address(vault), ALICE), 0);
    }

    function test_forcedETHIncludedAndWithdrawableWithoutAccountingDrift() public {
        _fund(11);
        new ForceETH{value: 19}(payable(address(vault)));
        assertEq(vault.buybackReserve(), 3 + 5);
        assertEq(vault.inferenceReserve(), 8 + 14);
        _fund(3);
        assertEq(vault.inferenceReserve() + vault.buybackReserve(), 33);
        vm.startPrank(vault.REFUEL_SAFE());
        vault.withdrawInference(25);
        vault.withdrawBuyback(8);
        vm.stopPrank();
        assertEq(address(vault).balance, 0);
    }
}
