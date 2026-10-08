// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, stdError} from "forge-std/Test.sol";
import {SovrnToken} from "src/SovrnToken.sol";

contract TokenFailurePathsTest is Test {
    SovrnToken private token;
    address private holder;
    address private spender;
    address private recipient;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    function setUp() public {
        holder = makeAddr("holder");
        spender = makeAddr("spender");
        recipient = makeAddr("recipient");
        token = new SovrnToken();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_failedTransferFromRestoresFiniteAllowance(uint96 raw, bool zeroRecipient) public {
        uint256 held = bound(raw, 0, 1e27 - 1);
        token.transfer(holder, held);
        vm.prank(holder);
        token.approve(spender, held + 1);
        address target = zeroRecipient ? address(0) : token.DEAD();
        vm.prank(spender);
        if (zeroRecipient) vm.expectRevert(SovrnToken.ZeroAddress.selector);
        else vm.expectRevert(stdError.arithmeticError);
        token.transferFrom(holder, target, held + 1);
        assertEq(token.allowance(holder, spender), held + 1, "reverted transfer spent allowance");
        assertEq(token.balanceOf(holder), held);
        assertEq(token.balanceOf(token.DEAD()), 0);
        assertEq(token.totalBurned(), 0);
        assertEq(token.totalSupply(), 1e27);
        // Failure must not disable a later valid spend.
        vm.prank(spender);
        assertTrue(token.transferFrom(holder, recipient, held));
        assertEq(token.allowance(holder, spender), 1);
        assertEq(token.balanceOf(recipient), held);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_allowanceCannotBeBypassedOrBorrowed(uint96 raw) public {
        uint256 amount = bound(raw, 1, 1e27);
        token.transfer(holder, amount);
        vm.prank(holder);
        token.approve(spender, amount - 1);
        vm.prank(spender);
        vm.expectRevert(stdError.arithmeticError);
        token.transferFrom(holder, recipient, amount);
        // The token's deployer has no authority over another holder's tokens.
        vm.expectRevert(stdError.arithmeticError);
        token.transferFrom(holder, address(this), 1);
        assertEq(token.balanceOf(holder), amount);
        assertEq(token.allowance(holder, spender), amount - 1);
        assertEq(token.allowance(holder, address(this)), 0);
        assertEq(token.balanceOf(recipient), 0);
    }

    function test_approvalOverwriteRevocationAndSelfSpend() public {
        token.transfer(holder, 10);
        vm.startPrank(holder);
        token.approve(spender, type(uint256).max);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(holder, spender, 4);
        token.approve(spender, 4);
        vm.stopPrank();
        vm.prank(spender);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(holder, holder, 3);
        assertTrue(token.transferFrom(holder, holder, 3));
        assertEq(token.balanceOf(holder), 10);
        assertEq(token.allowance(holder, spender), 1);
        vm.prank(holder);
        token.approve(spender, 0);
        vm.prank(spender);
        vm.expectRevert(stdError.arithmeticError);
        token.transferFrom(holder, recipient, 1);
        assertEq(token.balanceOf(holder), 10);
    }

    function test_zeroTransferFromNeedsNoAllowanceButCannotTargetZero() public {
        vm.prank(spender);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(holder, recipient, 0);
        assertTrue(token.transferFrom(holder, recipient, 0));
        assertEq(token.allowance(holder, spender), 0);
        vm.prank(spender);
        vm.expectRevert(SovrnToken.ZeroAddress.selector);
        token.transferFrom(holder, address(0), 0);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.totalBurned(), 0);
    }

    function test_infiniteAllowanceSurvivesBurnAndFailedBalanceCheck() public {
        token.transfer(holder, 10);
        vm.prank(holder);
        token.approve(spender, type(uint256).max);
        address dead = token.DEAD();
        vm.startPrank(spender);
        token.transferFrom(holder, dead, 10);
        vm.expectRevert(stdError.arithmeticError);
        token.transferFrom(holder, dead, 1);
        vm.stopPrank();
        assertEq(token.allowance(holder, spender), type(uint256).max);
        assertEq(token.balanceOf(dead), 10);
        assertEq(token.totalBurned(), 10);
        assertEq(token.totalSupply(), 1e27);
    }
}
