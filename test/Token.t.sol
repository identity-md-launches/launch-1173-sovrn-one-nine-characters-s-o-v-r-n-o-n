// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {SovrnToken} from "../src/SovrnToken.sol";

contract TokenTest is Test {
    function test_supplyPlainTransferAllowanceAndBurn() public {
        SovrnToken t = new SovrnToken();
        assertEq(t.name(), "SOVRN.ONE");
        assertEq(t.symbol(), "SVO");
        assertEq(bytes(t.name()).length, 9);
        assertEq(bytes(t.name())[5], bytes1(0x2e));
        assertEq(t.decimals(), 18);
        assertEq(t.totalSupply(), 1e27);
        assertEq(t.balanceOf(address(this)), 1e27);
        t.transfer(address(123), 1 ether);
        assertEq(t.balanceOf(address(123)), 1 ether);
        assertEq(t.totalSupply(), 1e27);
        address dead = t.DEAD();
        t.approve(address(123), 2 ether);
        vm.prank(address(123));
        t.transferFrom(address(this), dead, 2 ether);
        assertEq(t.totalBurned(), 2 ether);
        assertEq(t.balanceOf(t.DEAD()), 2 ether);
        assertEq(t.allowance(address(this), address(123)), 0);
        vm.prank(address(123));
        vm.expectRevert();
        t.transferFrom(address(this), address(123), 1);
        vm.expectRevert(SovrnToken.ZeroAddress.selector);
        t.transfer(address(0), 1);
        (bool minted,) = address(t).call(abi.encodeWithSignature("mint(address,uint256)", address(this), 1 ether));
        assertFalse(minted);
    }

    function test_infiniteAllowanceSelfTransferAndInsufficientBalance() public {
        SovrnToken t = new SovrnToken();
        t.approve(address(123), type(uint256).max);
        vm.prank(address(123));
        t.transferFrom(address(this), address(123), 1 ether);
        assertEq(t.allowance(address(this), address(123)), type(uint256).max);
        vm.prank(address(123));
        t.transfer(address(123), 1 ether);
        assertEq(t.balanceOf(address(123)), 1 ether);
        vm.prank(address(123));
        vm.expectRevert();
        t.transfer(address(this), 1 ether + 1);
        assertEq(t.balanceOf(address(123)), 1 ether);
        t.transfer(address(42), 0);
        assertEq(t.balanceOf(address(42)), 0);
        assertEq(t.totalSupply(), 1e27);
    }

    function testFuzz_plainTransfers(uint256 amount) public {
        SovrnToken t = new SovrnToken();
        amount = bound(amount, 0, t.totalSupply());
        t.transfer(address(42), amount);
        assertEq(t.balanceOf(address(42)), amount);
        assertEq(t.balanceOf(address(this)), t.totalSupply() - amount);
    }
}
