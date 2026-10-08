// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Vm} from "forge-std/Vm.sol";
import {SystemBase} from "./SystemBase.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {SovrnHook} from "src/SovrnHook.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

abstract contract FeeAssertions is SystemBase {
    bytes32 internal constant FEE_EVENT = keccak256("FeePaid(address,bool,uint256,uint256,bool)");
    bytes32 internal constant SWAP_EVENT =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    function _assertSettledFee(bool buy, int256 amount, uint160 limit) internal {
        uint256 payerETH = address(this).balance;
        uint256 payerSVO = token.balanceOf(address(this));
        uint256 managerETH = address(manager).balance;
        uint256 vaultETH = address(vault).balance;
        uint256 burned = token.totalBurned();
        vm.recordLogs();
        BalanceDelta delta = _trade(buy, amount, limit);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        uint256 fees;
        bool sawSwap;
        int128 ammETH;
        int128 ammSVO;
        uint256 gross;
        uint256 paidFee;
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].emitter == address(manager) && entries[i].topics[0] == SWAP_EVENT) {
                // recordLogs includes logs from reverted quote frames; the final Swap is the settled one.
                (ammETH, ammSVO,,,,) = abi.decode(entries[i].data, (int128, int128, uint160, uint128, int24, uint24));
                sawSwap = true;
            }
            if (entries[i].emitter != address(hook) || entries[i].topics[0] != FEE_EVENT) continue;
            ++fees;
            bool claims;
            (gross, paidFee, claims) = abi.decode(entries[i].data, (uint256, uint256, bool));
            assertEq(address(uint160(uint256(entries[i].topics[1]))), address(router));
            assertEq(uint256(entries[i].topics[2]), buy ? 1 : 0);
            assertFalse(claims, "funded fixture must settle directly");
        }
        assertEq(fees, 1, "quote must not persist fee events");
        assertTrue(sawSwap);
        assertEq(int256(delta.amount0()), int256(ammETH) - int256(paidFee));
        assertEq(delta.amount1(), ammSVO);
        uint256 rate = buy ? hook.launchFeeNow() : 35e15;
        assertEq(paidFee, gross * rate / 1e18, "fee on actual gross ETH");
        assertEq(address(vault).balance - vaultETH, paidFee);
        assertEq(token.totalBurned(), burned, "swaps do not tax SVO transfers");
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(address(hook).balance, 0);
        assertEq(address(router).balance, 0);
        if (buy) {
            assertEq(payerETH - address(this).balance, gross);
            assertEq(uint256(-int256(delta.amount0())), gross);
            assertEq(token.balanceOf(address(this)) - payerSVO, uint256(int256(delta.amount1())));
            assertEq(address(manager).balance + paidFee, managerETH + gross);
        } else {
            assertEq(address(this).balance - payerETH, gross - paidFee);
            assertEq(uint256(int256(delta.amount0())), gross - paidFee);
            assertEq(payerSVO - token.balanceOf(address(this)), uint256(-int256(delta.amount1())));
            assertEq(managerETH - address(manager).balance, gross);
        }
    }
}

contract AdversarialFeesTest is FeeAssertions {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _systemAtPrice(true, LAUNCH_PRICE, 1e21);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_actualSettlementAndEvents(uint96 raw, uint16 time, bool buy, bool exactInput, bool limited)
        public
    {
        vm.warp(hook.openedAt() + bound(time, 0, 7200));
        uint256 nativeAmount = bound(raw, 1, 0.01 ether);
        int256 amount = int256(buy == exactInput ? nativeAmount : nativeAmount * 100_000_000);
        if (exactInput) amount = -amount;
        uint160 limit = limited
            ? (buy ? LAUNCH_PRICE * 9999 / 10000 : LAUNCH_PRICE * 10001 / 10000)
            : (buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
        _assertSettledFee(buy, amount, limit);
    }

    function test_decaySecondAndMinuteBoundaries() public {
        uint256[8] memory elapsed = [uint256(0), 1, 59, 60, 1799, 1800, 3599, 3600];
        for (uint256 i; i < elapsed.length; ++i) {
            vm.warp(hook.openedAt() + elapsed[i]);
            assertEq(hook.launchFeeNow(), 35e15 + 465e15 * (3600 - elapsed[i]) / 3600);
            assertEq(hook.decayMinutesLeft(), (3659 - elapsed[i]) / 60);
        }
        vm.warp(hook.openedAt() + 3601);
        assertEq(hook.launchFeeNow(), 35e15);
        assertEq(hook.decayMinutesLeft(), 0);
    }

    function test_quoteLeavesSamePriceLiquidityAndLPGrowthAsUnhookedPool() public {
        PoolKey memory referenceKey = key;
        referenceKey.hooks = IHooks(address(0));
        manager.initialize(referenceKey, LAUNCH_PRICE);
        router.liquidity{value: 10 ether}(referenceKey, ModifyLiquidityParams(-887220, 887220, 1e21, bytes32(0)));
        vm.warp(hook.openedAt() + 1 hours);
        BalanceDelta actual = _trade(true, -0.01 ether);
        BalanceDelta referenceDelta = router.trade{value: 0.01 ether}(
            referenceKey, SwapParams(true, -0.00965 ether, TickMath.MIN_SQRT_PRICE + 1)
        );
        assertEq(actual.amount1(), referenceDelta.amount1());
        _sameAMMState(referenceKey);
        actual = _trade(false, 0.001 ether);
        uint256 gross = uint256(0.001 ether) * 1000 / 965;
        referenceDelta = router.trade(referenceKey, SwapParams(false, int256(gross), TickMath.MAX_SQRT_PRICE - 1));
        assertEq(actual.amount1(), referenceDelta.amount1());
        assertEq(actual.amount0(), 0.001 ether);
        _sameAMMState(referenceKey);
    }

    function _sameAMMState(PoolKey memory other) private view {
        IPoolManager m = IPoolManager(address(manager));
        (uint160 price, int24 tick,,) = m.getSlot0(key.toId());
        (uint160 referencePrice, int24 referenceTick,,) = m.getSlot0(other.toId());
        assertEq(price, referencePrice, "quote changed final price");
        assertEq(tick, referenceTick);
        assertEq(m.getLiquidity(key.toId()), m.getLiquidity(other.toId()));
        (uint256 growth0, uint256 growth1) = m.getFeeGrowthGlobals(key.toId());
        (uint256 expected0, uint256 expected1) = m.getFeeGrowthGlobals(other.toId());
        assertEq(growth0, expected0, "quote persisted native LP fees");
        assertEq(growth1, expected1, "quote persisted SovrnToken LP fees");
    }

    function test_callbackRejectsZeroAndNarrowingOverflow() public {
        int256[4] memory amounts =
            [int256(0), int256(type(int128).max) + 1, -int256(type(int128).max) - 1, type(int256).min];
        for (uint256 i; i < amounts.length; ++i) {
            vm.prank(address(manager));
            vm.expectRevert(SovrnHook.InvalidAmount.selector);
            hook.beforeSwap(address(router), key, SwapParams(true, amounts[i], LAUNCH_PRICE / 2), "");
        }
        // A refused callback must not leave the hook busy.
        _assertSettledFee(true, -0.001 ether, TickMath.MIN_SQRT_PRICE + 1);
    }

    function test_wrongPoolEveryBoundFieldAndUnpairedAfterSwap() public {
        for (uint256 i; i < 5; ++i) {
            PoolKey memory bad = key;
            if (i == 0) bad.currency0 = Currency.wrap(address(token));
            if (i == 1) bad.currency1 = Currency.wrap(ALICE);
            if (i == 2) bad.fee = 3000;
            if (i == 3) bad.tickSpacing = 120;
            if (i == 4) bad.hooks = IHooks(ALICE);
            vm.prank(address(manager));
            vm.expectRevert(SovrnHook.WrongPool.selector);
            hook.beforeSwap(address(router), bad, SwapParams(true, -1, LAUNCH_PRICE / 2), "");
            vm.prank(address(manager));
            vm.expectRevert(SovrnHook.WrongPool.selector);
            hook.afterSwap(address(router), bad, SwapParams(true, -1, LAUNCH_PRICE / 2), BalanceDelta.wrap(0), "");
        }
        vm.prank(address(manager));
        vm.expectRevert(SovrnHook.Unauthorized.selector);
        hook.afterSwap(address(router), key, SwapParams(true, -1, LAUNCH_PRICE / 2), BalanceDelta.wrap(0), "");
        vm.prank(address(manager));
        vm.expectRevert(SovrnHook.Unauthorized.selector);
        hook.unlockCallback(abi.encode(1, 2, 3));
    }
}
