// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SystemBase} from "./SystemBase.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

/// @notice Compare to an equally seeded, unhooked real v4 pool, including protocol fees.
///         The oracle is actual AMM movement, not the hook's FeePaid event.
contract FeeDifferentialTest is SystemBase {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    PoolKey private referenceKey;

    function setUp() public {
        _systemAtPrice(true, LAUNCH_PRICE, 1e21);
        referenceKey = abi.decode(abi.encode(key), (PoolKey));
        referenceKey.hooks = IHooks(address(0));
        manager.initialize(referenceKey, _orient(LAUNCH_PRICE));
        router.liquidity(referenceKey, ModifyLiquidityParams(-887220, 887220, 1e21, bytes32(0)));
        manager.setProtocolFeeController(address(this));
        // Distinct, nonzero protocol fees in both directions exercise quote rollback.
        uint24 protocolFee = 500 | (uint24(1000) << 12);
        manager.setProtocolFee(key, protocolFee);
        manager.setProtocolFee(referenceKey, protocolFee);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_referencePoolAllModes(uint8 mode, uint96 raw, uint16 elapsed, uint16 limitBps, bool limited)
        public
    {
        _compare(mode % 4, bound(raw, 1, 0.01 ether), bound(elapsed, 0, 7200), limited ? bound(limitBps, 1, 100) : 0);
    }

    function test_allFourModesAtEveryRequiredDecayTime() public {
        uint256[3] memory elapsed = [uint256(0), 1800, 3600];
        for (uint256 i; i < elapsed.length; ++i) {
            for (uint8 mode; mode < 4; ++mode) {
                uint256 snapshot = vm.snapshotState();
                _compare(mode, 0.001 ether, elapsed[i], 0);
                assertTrue(vm.revertToStateAndDelete(snapshot));
            }
        }
    }

    function _compare(uint8 mode, uint256 imdAmount, uint256 elapsed, uint256 limitBps) private {
        bool buy = mode < 2;
        bool exactInput = mode % 2 == 0;
        vm.warp(hook.openedAt() + elapsed);
        uint256 rate = buy && elapsed < 3600 ? 35e15 + 465e15 * (3600 - elapsed) / 3600 : 35e15;
        uint256 specified = buy == exactInput ? imdAmount : imdAmount * 100_000_000;
        int256 amount = exactInput ? -int256(specified) : int256(specified);
        uint160 limit = buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        if (limitBps != 0) {
            limit = uint160(uint256(LAUNCH_PRICE) * (buy ? 10000 - limitBps : 10000 + limitBps) / 10000);
        }

        int256 referenceAmount = amount;
        if (buy && exactInput) referenceAmount = -int256(specified - specified * rate / 1e18);
        if (!buy && !exactInput) referenceAmount = int256(specified * 1e18 / (1e18 - rate));
        Currency input = Currency.wrap(buy ? IMD_ADDR : address(token));
        uint256 protocolBefore = manager.protocolFeesAccrued(input);
        BalanceDelta amm = router.trade(referenceKey, SwapParams(buy == _imdIsCurrency0(), referenceAmount, _orient(limit)));
        uint256 protocolAfterReference = manager.protocolFeesAccrued(input);
        uint256 imdMoved = uint256(buy ? -int256(_imdLeg(amm)) : int256(_imdLeg(amm)));
        uint256 expectedFee;
        if (!buy) expectedFee = imdMoved * rate / 1e18;
        else if (exactInput && imdMoved == uint256(-referenceAmount)) expectedFee = specified * rate / 1e18;
        else expectedFee = imdMoved * rate / (1e18 - rate);

        uint256 vaultBefore = _vaultIMD();
        uint256 managerBefore = imd.balanceOf(address(manager));
        uint256 payerBefore = imd.balanceOf(address(this));
        uint256 svoBefore = token.balanceOf(address(this));
        BalanceDelta actual = _trade(buy, amount, limit);
        assertEq(int256(_imdLeg(actual)), int256(_imdLeg(amm)) - int256(expectedFee), "IMD delta");
        assertEq(_svoLeg(actual), _svoLeg(amm), "fee must not tax SVO");
        assertEq(int256(imd.balanceOf(address(this))) - int256(payerBefore), int256(_imdLeg(actual)));
        assertEq(int256(token.balanceOf(address(this))) - int256(svoBefore), int256(_svoLeg(actual)));
        assertEq(int256(imd.balanceOf(address(manager))) - int256(managerBefore), -int256(_imdLeg(amm)));
        assertEq(_vaultIMD() - vaultBefore, expectedFee, "entire fee to vault");
        assertEq(vault.buybackReserve(), expectedFee * 3 / 10);
        assertEq(vault.inferenceReserve(), expectedFee - expectedFee * 3 / 10);
        assertEq(hook.claimFees(), 0);
        assertEq(
            manager.protocolFeesAccrued(input) - protocolAfterReference,
            protocolAfterReference - protocolBefore,
            "quote must not accrue protocol fees twice"
        );

        IPoolManager m = IPoolManager(address(manager));
        (uint160 price, int24 tick, uint24 protocol, uint24 lp) = m.getSlot0(key.toId());
        (uint160 refPrice, int24 refTick, uint24 refProtocol, uint24 refLp) = m.getSlot0(referenceKey.toId());
        assertEq(abi.encode(price, tick, protocol, lp), abi.encode(refPrice, refTick, refProtocol, refLp));
        assertEq(m.getLiquidity(key.toId()), m.getLiquidity(referenceKey.toId()));
        (uint256 growth0, uint256 growth1) = m.getFeeGrowthGlobals(key.toId());
        (uint256 refGrowth0, uint256 refGrowth1) = m.getFeeGrowthGlobals(referenceKey.toId());
        assertEq(growth0, refGrowth0);
        assertEq(growth1, refGrowth1);
        assertEq(m.getNonzeroDeltaCount(), 0);
        assertFalse(m.isUnlocked());
        assertEq(m.currencyDelta(address(hook), key.currency0), 0);
        assertEq(m.currencyDelta(address(hook), key.currency1), 0);
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(imd.balanceOf(address(router)), 0);
    }
}

contract FeeDifferentialReversedTest is FeeDifferentialTest {
    function _imdIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
