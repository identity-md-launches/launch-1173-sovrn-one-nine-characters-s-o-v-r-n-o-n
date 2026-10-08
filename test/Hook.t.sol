// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {SystemBase} from "./SystemBase.sol";
import {SovrnHook} from "../src/SovrnHook.sol";
import {SovrnToken} from "../src/SovrnToken.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

contract RejectETH {
    receive() external payable {
        revert();
    }
}

contract HookTest is SystemBase {
    function setUp() public {
        _system(true);
        vm.warp(hook.openedAt() + 1 hours);
    }

    function _checkFee(bool buy, int256 amount, uint160 limit) internal {
        uint256 beforeVault = address(vault).balance;
        BalanceDelta d = _trade(buy, amount, limit);
        uint256 fee = address(vault).balance - beforeVault;
        uint256 gross = buy ? uint256(-int256(d.amount0())) : uint256(int256(d.amount0())) + fee;
        assertEq(fee, gross * 350 / 10000);
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertGt(fee, 0);
        if (buy && amount < 0) assertLe(gross, uint256(-amount));
        if (!buy && amount > 0) assertLe(uint256(int256(d.amount0())), uint256(amount));
    }

    function test_feeAllFourModes() public {
        _checkFee(true, -0.1 ether, 4295128740);
        _checkFee(true, 10_000 ether, 4295128740);
        _checkFee(false, -10_000 ether, 1461446703485210103287273052203988822378723970341);
        _checkFee(false, 0.05 ether, 1461446703485210103287273052203988822378723970341);
    }

    function test_partialBuyExactInput() public {
        _checkFee(true, -5 ether, START_PRICE * 99 / 100);
    }

    function test_partialBuyExactOutput() public {
        _checkFee(true, 5_000_000 ether, START_PRICE * 99 / 100);
    }

    function test_partialSellExactInput() public {
        _checkFee(false, -5_000_000 ether, START_PRICE * 101 / 100);
    }

    function test_partialSellExactOutput() public {
        _checkFee(false, 5 ether, START_PRICE * 101 / 100);
    }

    function test_exactModesRespectAmount() public {
        assertEq(_trade(true, -0.1 ether).amount0(), -0.1 ether);
        assertEq(_trade(true, 20_000 ether).amount1(), 20_000 ether);
        assertEq(_trade(false, -20_000 ether).amount1(), -20_000 ether);
        assertEq(_trade(false, 0.1 ether).amount0(), 0.1 ether);
    }

    function test_decayAndFullFeeToVault() public {
        uint256 opened = hook.openedAt();
        vm.warp(opened);
        assertEq(hook.launchFeeNow(), 0.5e18);
        assertEq(hook.decayMinutesLeft(), 60);
        _trade(true, -1 ether);
        assertEq(address(vault).balance, 0.5 ether);
        assertEq(vault.inferenceReserve(), 0.35 ether);
        assertEq(vault.buybackReserve(), 0.15 ether);
        vm.warp(opened + 30 minutes);
        assertEq(hook.launchFeeNow(), 0.2675e18);
        assertEq(hook.decayMinutesLeft(), 30);
        vm.warp(opened + 1 hours);
        assertEq(hook.launchFeeNow(), 0.035e18);
        assertEq(hook.decayMinutesLeft(), 0);
        vm.warp(opened + 100 days);
        assertEq(hook.launchFeeNow(), 0.035e18);
    }

    function test_sellsStayAtNormalFee() public {
        _trade(true, -0.1 ether);
        vm.warp(hook.openedAt());
        _checkFee(false, -10_000 ether, 1461446703485210103287273052203988822378723970341);
    }

    function test_permissionsAndUnauthorizedCallbacks() public {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(
            p.beforeInitialize && p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta && p.afterSwapReturnDelta
        );
        vm.expectRevert(SovrnHook.Unauthorized.selector);
        hook.beforeInitialize(address(this), key, START_PRICE);
        vm.expectRevert(SovrnHook.Unauthorized.selector);
        hook.beforeSwap(address(this), key, SwapParams(true, -1 ether, START_PRICE / 2), "");
        vm.expectRevert(SovrnHook.Unauthorized.selector);
        hook.afterSwap(address(this), key, SwapParams(true, -1 ether, START_PRICE / 2), BalanceDelta.wrap(0), "");
        vm.expectRevert(SovrnHook.Unauthorized.selector);
        hook.unlockCallback("");
        vm.expectRevert(SovrnHook.Unauthorized.selector);
        hook.quoteIMD(key, SwapParams(true, -1 ether, START_PRICE / 2));
    }

    function test_wrongPoolRejected() public {
        PoolKey memory other = key;
        other.fee = 3000;
        vm.expectRevert();
        manager.initialize(other, START_PRICE);
        other = key;
        other.tickSpacing = 10;
        vm.expectRevert();
        manager.initialize(other, START_PRICE);
    }

    function testFuzz_feeBuyAndSell(uint96 raw, bool buy, bool exactInput) public {
        uint256 amount = bound(uint256(raw), 1e12, 1e17);
        int256 specified = int256(buy == exactInput ? amount : amount * 1_000_000);
        if (exactInput) specified = -specified;
        _checkFee(buy, specified, buy ? 4295128740 : 1461446703485210103287273052203988822378723970341);
    }
}
