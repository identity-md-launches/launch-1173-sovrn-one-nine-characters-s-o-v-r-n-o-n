// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SystemBase} from "./SystemBase.sol";
import {ForceETH} from "./Vault.t.sol";
import {SovrnHook} from "src/SovrnHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract RedemptionDuringUnlock {
    IPoolManager private immutable manager;
    SovrnHook private immutable hook;

    constructor(IPoolManager m, SovrnHook h) {
        manager = m;
        hook = h;
    }

    function attempt() external returns (bool, bytes memory) {
        return abi.decode(manager.unlock(""), (bool, bytes));
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (bool ok, bytes memory reason) = address(hook).call(abi.encodeCall(hook.redeemFees, ()));
        return abi.encode(ok, reason);
    }
}

contract SettlementFailuresTest is SystemBase {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    event ClaimsRedeemed(uint256 amount);
    event LifeForceFunded(address indexed from, uint256 amount, uint256 inference, uint256 buyback);

    function setUp() public {
        vm.chainId(11155111);
        _systemAtPrice(false, LAUNCH_PRICE, 0);
        router.liquidity(key, ModifyLiquidityParams(166200, 184200, 1e21, bytes32(0)));
        assertEq(address(manager).balance, 0);
    }

    function test_managerBalanceAtFeeThresholdPaysEntireFeeOneWay() public {
        uint256 fee = 0.005 ether;
        uint256[4] memory backing = [uint256(0), fee - 1, fee, fee + 1];
        for (uint256 i; i < backing.length; ++i) {
            uint256 snapshot = vm.snapshotState();
            new ForceETH{value: backing[i]}(payable(address(manager)));
            bool claim = backing[i] < fee;
            if (!claim) {
                vm.expectEmit(true, false, false, true, address(vault));
                emit LifeForceFunded(address(manager), fee, 0.0035 ether, 0.0015 ether);
            }
            BalanceDelta d = _trade(true, -0.01 ether);
            assertEq(d.amount0(), -0.01 ether);
            assertEq(hook.claimFees(), claim ? fee : 0);
            assertEq(manager.balanceOf(address(hook), 0), claim ? fee : 0);
            assertEq(address(vault).balance, claim ? 0 : fee);
            assertEq(address(manager).balance, backing[i] + 0.01 ether - (claim ? 0 : fee));
            if (claim) {
                vm.expectEmit(false, false, false, true, address(hook));
                emit ClaimsRedeemed(fee);
            }
            vm.prank(ALICE);
            hook.redeemFees();
            assertEq(address(vault).balance, fee);
            assertEq(vault.inferenceReserve(), 0.0035 ether);
            assertEq(vault.buybackReserve(), 0.0015 ether);
            assertEq(hook.claimFees(), 0);
            assertEq(manager.balanceOf(address(hook), 0), 0);
            assertEq(address(manager).balance, backing[i] + 0.005 ether);
            _assertSettled();
            assertTrue(vm.revertToStateAndDelete(snapshot));
        }
    }

    function test_underpaidSwapRollsBackDirectFeesAndClaims() public {
        for (uint256 i; i < 2; ++i) {
            uint256 snapshot = vm.snapshotState();
            if (i == 1) new ForceETH{value: 1 ether}(payable(address(manager)));
            bytes32 beforeState = _stateDigest();
            // Fee collection occurs before router settlement. The router has no ETH
            // to settle the trader's input, so the whole unlock must roll back.
            vm.expectRevert();
            router.trade(key, SwapParams(true, -0.01 ether, TickMath.MIN_SQRT_PRICE + 1));
            assertEq(_stateDigest(), beforeState, "failed settlement persisted state");
            _assertSettled();
            _trade(true, -0.01 ether);
            assertEq(address(vault).balance + hook.claimFees(), 0.005 ether);
            hook.redeemFees();
            assertEq(address(vault).balance, 0.005 ether);
            assertTrue(vm.revertToStateAndDelete(snapshot));
        }
    }

    function test_unpaidTokenInputRollsBackSellAndRestoresAllowance() public {
        _trade(true, -0.01 ether);
        hook.redeemFees();
        token.approve(address(router), 1);
        bytes32 beforeState = _stateDigest();
        vm.expectRevert();
        router.trade(key, SwapParams(false, -1000 ether, TickMath.MAX_SQRT_PRICE - 1));
        assertEq(_stateDigest(), beforeState);
        assertEq(token.allowance(address(this), address(router)), 1);
        _assertSettled();
        token.approve(address(router), 1000 ether);
        BalanceDelta d = _trade(false, -1000 ether);
        assertEq(d.amount1(), -1000 ether);
        assertEq(token.allowance(address(this), address(router)), 0);
    }

    function test_dustFeesSplitPerReceiptForDirectAndAccumulatedClaims() public {
        // At the opening 50% rate these buys pay 3, 9 and 27 wei. On an
        // empty manager each next fee exceeds the ETH settled by earlier buys.
        uint256[3] memory amounts = [uint256(6), 18, 54];
        for (uint256 direct; direct < 2; ++direct) {
            uint256 snapshot = vm.snapshotState();
            uint256 backing = direct == 1 ? 100 : 0;
            if (backing != 0) new ForceETH{value: backing}(payable(address(manager)));
            uint256 fees;
            for (uint256 i; i < amounts.length; ++i) {
                BalanceDelta d = _trade(true, -int256(amounts[i]));
                assertEq(int256(d.amount0()), -int256(amounts[i]));
                fees += amounts[i] / 2;
                assertEq(hook.claimFees(), direct == 1 ? 0 : fees);
                assertEq(manager.balanceOf(address(hook), 0), direct == 1 ? 0 : fees);
                assertEq(address(vault).balance, direct == 1 ? fees : 0);
            }
            assertEq(fees, 39);
            if (direct == 0) {
                vm.expectEmit(true, false, false, true, address(vault));
                emit LifeForceFunded(address(manager), 39, 28, 11);
            }
            uint256 callerBefore = ALICE.balance;
            vm.prank(ALICE);
            hook.redeemFees();
            // Three direct receipts round separately: 0 + 2 + 8 buyback wei.
            // Accumulated claims are one 39-wei receipt: floor(39 * 3 / 10).
            assertEq(vault.buybackReserve(), direct == 1 ? 10 : 11);
            assertEq(vault.inferenceReserve(), direct == 1 ? 29 : 28);
            assertEq(address(vault).balance, 39);
            assertEq(address(manager).balance, backing + 39);
            assertEq(ALICE.balance, callerBefore, "redemption must only pay the vault");
            assertEq(hook.claimFees(), 0);
            assertEq(manager.balanceOf(address(hook), 0), 0);
            bytes32 redeemed = _stateDigest();
            hook.redeemFees();
            assertEq(_stateDigest(), redeemed, "repeated redemption must not pay twice");
            _assertSettled();
            assertTrue(vm.revertToStateAndDelete(snapshot));
        }
    }

    function test_zeroRoundedFeePreservesPendingClaims() public {
        _trade(true, -6);
        assertEq(hook.claimFees(), 3);
        BalanceDelta d = _trade(true, -1);
        assertEq(d.amount0(), -1);
        assertEq(hook.claimFees(), 3);
        assertEq(manager.balanceOf(address(hook), 0), 3);
        assertEq(address(vault).balance, 0);
        assertEq(address(manager).balance, 7);
        hook.redeemFees();
        assertEq(vault.inferenceReserve(), 3);
        assertEq(vault.buybackReserve(), 0);
        assertEq(address(vault).balance, 3);
        assertEq(address(manager).balance, 4);
        assertEq(hook.claimFees(), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        _assertSettled();
    }

    function test_failedSettlementPreservesEarlierClaimsInBothPaymentModes() public {
        _trade(true, -0.001 ether);
        assertEq(hook.claimFees(), 0.0005 ether);
        for (uint256 direct; direct < 2; ++direct) {
            uint256 snapshot = vm.snapshotState();
            if (direct == 1) new ForceETH{value: 1 ether}(payable(address(manager)));
            bytes32 beforeState = _stateDigest();
            // The second fee is 0.005 ETH. Without extra backing it mints
            // another claim; with backing it pays the vault before settlement.
            vm.expectRevert();
            router.trade(key, SwapParams(true, -0.01 ether, TickMath.MIN_SQRT_PRICE + 1));
            assertEq(_stateDigest(), beforeState, "failed trade changed earlier fees");
            _assertSettled();
            _trade(true, -0.01 ether);
            assertEq(hook.claimFees(), direct == 1 ? 0.0005 ether : 0.0055 ether);
            assertEq(manager.balanceOf(address(hook), 0), hook.claimFees());
            assertEq(address(vault).balance, direct == 1 ? 0.005 ether : 0);
            vm.prank(BOB);
            hook.redeemFees();
            assertEq(hook.claimFees(), 0);
            assertEq(manager.balanceOf(address(hook), 0), 0);
            assertEq(address(vault).balance, 0.0055 ether);
            assertEq(vault.inferenceReserve(), 0.00385 ether);
            assertEq(vault.buybackReserve(), 0.00165 ether);
            _assertSettled();
            assertTrue(vm.revertToStateAndDelete(snapshot));
        }
    }

    function test_nestedUnlockRedemptionFailsAtomicallyAndCanRetry() public {
        _trade(true, -0.01 ether);
        RedemptionDuringUnlock probe = new RedemptionDuringUnlock(manager, hook);
        bytes32 beforeState = _stateDigest();
        (bool ok, bytes memory reason) = probe.attempt();
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(IPoolManager.AlreadyUnlocked.selector));
        assertEq(_stateDigest(), beforeState);
        _assertSettled();
        vm.prank(BOB);
        hook.redeemFees();
        assertEq(address(vault).balance, 0.005 ether);
        assertEq(hook.claimFees(), 0);
        (ok, reason) = probe.attempt();
        assertTrue(ok, "zero claims should not attempt nested unlock");
        assertEq(reason.length, 0);
        _trade(true, -0.001 ether);
        assertEq(address(vault).balance, 0.0055 ether);
        _assertSettled();
    }

    function test_failedQuoteBubblesUpAndDoesNotKeepBusyState() public {
        bytes32 beforeState = _stateDigest();
        // Buy limits must be below the current price. This fails inside the nested quote.
        vm.expectRevert();
        router.trade{value: 0.01 ether}(key, SwapParams(true, -0.01 ether, LAUNCH_PRICE + 1));
        assertEq(_stateDigest(), beforeState);
        _assertSettled();
        _trade(true, -0.01 ether);
        assertEq(hook.claimFees(), 0.005 ether);
    }

    function _stateDigest() private view returns (bytes32) {
        IPoolManager m = IPoolManager(address(manager));
        (uint160 price, int24 tick,,) = m.getSlot0(key.toId());
        (uint256 growth0, uint256 growth1) = m.getFeeGrowthGlobals(key.toId());
        return keccak256(
            abi.encode(
                price,
                tick,
                growth0,
                growth1,
                m.getLiquidity(key.toId()),
                address(manager).balance,
                address(vault).balance,
                address(this).balance,
                token.balanceOf(address(manager)),
                token.balanceOf(address(this)),
                vault.inferenceReserve(),
                vault.buybackReserve(),
                hook.claimFees(),
                manager.balanceOf(address(hook), 0),
                token.totalBurned(),
                hook.openedAt()
            )
        );
    }

    function _assertSettled() private view {
        IPoolManager m = IPoolManager(address(manager));
        assertFalse(m.isUnlocked());
        assertEq(m.getNonzeroDeltaCount(), 0);
        assertEq(m.currencyDelta(address(hook), key.currency0), 0);
        assertEq(m.currencyDelta(address(hook), key.currency1), 0);
        assertEq(m.currencyDelta(address(router), key.currency0), 0);
        assertEq(m.currencyDelta(address(router), key.currency1), 0);
        assertEq(address(hook).balance, 0);
        assertEq(address(router).balance, 0);
    }
}
