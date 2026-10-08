// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {ReviewBatchRouter} from "./ReviewRegression.t.sol";
import {SystemBase} from "./SystemBase.sol";
import {RejectETH} from "./Hook.t.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

contract LaunchPolicyTest is SystemBase {
    using StateLibrary for IPoolManager;

    function test_launchPriceSupportsFourModesAndFullVaultFunding() public {
        vm.chainId(11155111);
        _systemAtPrice(true, LAUNCH_PRICE, 1e21);
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(price, LAUNCH_PRICE);
        BalanceDelta first = _trade(true, -0.01 ether);
        assertEq(first.amount0(), -0.01 ether);
        assertGt(first.amount1(), 0);
        assertEq(address(vault).balance, 0.005 ether);
        assertEq(vault.inferenceReserve(), 0.0035 ether);
        assertEq(vault.buybackReserve(), 0.0015 ether);
        vm.warp(hook.openedAt() + 1 hours);
        _normalFee(true, -0.001 ether);
        _normalFee(true, 10_000 ether);
        _normalFee(false, -10_000 ether);
        _normalFee(false, 0.001 ether);
    }

    // Regression for the imported stranded-fees proof, on the specified launch chain and price.
    function test_allFeeETHIsReleasableOnLaunchChain() public {
        vm.chainId(11155111);
        _systemAtPrice(true, LAUNCH_PRICE, 1e21);
        vm.warp(hook.openedAt() + 1 hours);
        _trade(true, -1 ether);
        assertEq(address(vault).balance, 0.035 ether);
        assertEq(address(hook).balance, 0);
        uint256 safeBefore = vault.REFUEL_SAFE().balance;
        uint256 inference = vault.inferenceReserve();
        uint256 buyback = vault.buybackReserve();
        vm.startPrank(vault.REFUEL_SAFE());
        vault.withdrawInference(inference);
        vault.withdrawBuyback(buyback);
        vm.stopPrank();
        assertEq(vault.REFUEL_SAFE().balance - safeBefore, 0.035 ether);
        assertEq(address(vault).balance, 0);
    }

    function _normalFee(bool buy, int256 amount) private {
        uint256 beforeVault = address(vault).balance;
        BalanceDelta delta = _trade(buy, amount);
        uint256 fee = address(vault).balance - beforeVault;
        uint256 gross = buy ? uint256(-int256(delta.amount0())) : uint256(int256(delta.amount0())) + fee;
        assertEq(fee, gross * 350 / 10_000);
        if (buy && amount < 0) assertEq(delta.amount0(), amount);
        if (buy && amount > 0) assertEq(delta.amount1(), amount);
        if (!buy && amount < 0) assertEq(delta.amount1(), amount);
        if (!buy && amount > 0) assertEq(delta.amount0(), amount);
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
    }
}

contract FreshManagerTest is SystemBase {
    function setUp() public {
        _systemAtPrice(false, LAUNCH_PRICE, 0);
        // All SVO at opening. This is a test range, not a launch liquidity allocation.
        router.liquidity(key, ModifyLiquidityParams(166200, 184200, 1e21, bytes32(0)));
        assertEq(address(manager).balance, 0);
    }

    function testFuzz_firstBuyClaimsBothExactModesAndDecay(bool exactInput, uint16 elapsed) public {
        vm.warp(hook.openedAt() + bound(elapsed, 0, 7200));
        BalanceDelta first = _trade(true, exactInput ? -int256(0.01 ether) : int256(10_000 ether));
        uint256 gross = uint256(-int256(first.amount0()));
        uint256 expected = gross * hook.launchFeeNow() / 1e18;
        assertGt(expected, 0);
        assertEq(hook.claimFees(), expected);
        assertEq(manager.balanceOf(address(hook), 0), expected);
        assertEq(address(vault).balance, 0);
        assertEq(vault.inferenceReserve() + vault.buybackReserve(), 0);
        vm.prank(BOB);
        hook.redeemFees();
        assertEq(hook.claimFees(), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertEq(address(vault).balance, expected);
        assertEq(vault.buybackReserve(), expected * 3000 / 10000);
        assertEq(vault.inferenceReserve(), expected - expected * 3000 / 10000);
        hook.redeemFees();
        assertEq(address(vault).balance, expected);
    }

    function test_allFourModesMintClaimsInOneUnlockOnEmptyManager() public {
        vm.warp(hook.openedAt() + 1 hours);
        ReviewBatchRouter batch = new ReviewBatchRouter(manager);
        vm.recordLogs();
        batch.execute{value: 1 ether}(key);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 count;
        uint256 fees;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter != address(hook)
                    || logs[i].topics[0] != keccak256("FeePaid(address,bool,uint256,uint256,bool)")
            ) continue;
            (uint256 gross, uint256 fee, bool claim) = abi.decode(logs[i].data, (uint256, uint256, bool));
            assertTrue(claim);
            assertEq(fee, gross * 35 / 1000);
            fees += fee;
            ++count;
        }
        assertEq(count, 4);
        assertEq(hook.claimFees(), fees);
        assertEq(manager.balanceOf(address(hook), 0), fees);
        assertEq(address(vault).balance, 0);
        hook.redeemFees();
        assertEq(address(vault).balance, fees);
        assertEq(hook.claimFees(), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
    }

    function test_claimAndDirectFeesMixedBeforeRedemption() public {
        _trade(true, -0.001 ether);
        assertEq(hook.claimFees(), 0.0005 ether);
        _trade(true, -0.001 ether);
        assertEq(hook.claimFees(), 0.0005 ether);
        assertEq(address(vault).balance, 0.0005 ether);
        vm.prank(ALICE);
        hook.redeemFees();
        assertEq(hook.claimFees(), 0);
        assertEq(address(vault).balance, 0.001 ether);
        assertEq(vault.inferenceReserve(), 0.0007 ether);
        assertEq(vault.buybackReserve(), 0.0003 ether);
    }

    function test_failedRedemptionRestoresClaimsAndCanRetry() public {
        _trade(true, -0.001 ether);
        uint256 backing = address(manager).balance;
        vm.deal(address(manager), 0);
        vm.expectRevert();
        hook.redeemFees();
        assertEq(hook.claimFees(), 0.0005 ether);
        assertEq(manager.balanceOf(address(hook), 0), 0.0005 ether);
        vm.deal(address(manager), backing);
        hook.redeemFees();
        assertEq(address(vault).balance, 0.0005 ether);
        assertEq(hook.claimFees(), 0);
    }

    function test_rejectingVaultDoesNotBlockClaimMintButRedemptionReverts() public {
        bytes memory original = address(vault).code;
        vm.etch(address(vault), address(new RejectETH()).code);
        _trade(true, -0.001 ether);
        assertEq(hook.claimFees(), 0.0005 ether);
        vm.expectRevert();
        hook.redeemFees();
        assertEq(hook.claimFees(), 0.0005 ether);
        assertEq(manager.balanceOf(address(hook), 0), 0.0005 ether);
        vm.etch(address(vault), original);
        hook.redeemFees();
        assertEq(address(vault).balance, 0.0005 ether);
    }
}
