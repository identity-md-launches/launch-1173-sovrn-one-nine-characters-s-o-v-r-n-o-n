// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {SystemBase} from "./SystemBase.sol";
import {PoolRouter} from "./PoolRouter.sol";
import {SovrnHook} from "../src/SovrnHook.sol";
import {SovrnToken} from "../src/SovrnToken.sol";
import {LifeForceVault} from "../src/LifeForceVault.sol";
import {MockIMD} from "./mocks/MockERC20.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract LifecycleHandler is Test {
    SovrnHook public immutable hook;
    LifeForceVault public immutable vault;
    SovrnToken public immutable token;
    PoolRouter private immutable router;
    MockIMD private immutable imd;
    bool private immutable imdIsCurrency0;
    uint256 public fees;
    uint256 public donations;
    uint256 public paid;
    uint256 public burned;
    bool private rejecting;

    constructor(SovrnHook h, PoolRouter r) {
        hook = h;
        vault = h.vault();
        token = h.token();
        router = r;
        imd = MockIMD(h.IMD());
        imdIsCurrency0 = h.imdIsCurrency0();
        token.approve(address(r), type(uint256).max);
        imd.approve(address(r), type(uint256).max);
    }

    function swap(uint96 raw, bool buy, bool exactInput) public {
        uint256 imdAmount = bound(raw, 1, 0.0001 ether);
        int256 amount = int256(buy == exactInput ? imdAmount : imdAmount * 100_000_000);
        if (exactInput) amount = -amount;
        // A BUY pays IMD in: zeroForOne exactly when IMD is currency0.
        bool zeroForOne = buy == imdIsCurrency0;
        vm.recordLogs();
        router.trade(
            hook.poolKey(),
            SwapParams(zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1)
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter != address(hook)
                    || logs[i].topics[0] != keccak256("FeePaid(address,bool,uint256,uint256,bool)")
            ) continue;
            (uint256 gross, uint256 fee,) = abi.decode(logs[i].data, (uint256, uint256, bool));
            assertEq(fee, gross * (buy ? hook.launchFeeNow() : 35e15) / 1e18);
            fees += fee;
        }
    }

    function advance(uint32 raw) public {
        vm.warp(block.timestamp + bound(raw, 0, 7200));
    }

    function redeem() public {
        hook.redeemFees();
    }

    function donate(uint96 raw, bool forced) public {
        uint256 amount = bound(raw, 0, 1 ether);
        donations += amount;
        if (forced) {
            // Credit the vault without a transfer call (as a seizure-free airdrop or rebase would).
            deal(address(imd), address(vault), imd.balanceOf(address(vault)) + amount);
        } else {
            assertTrue(imd.transfer(address(vault), amount));
        }
    }

    function withdraw(uint96 raw, bool inference) public {
        uint256 available = inference ? vault.inferenceReserve() : vault.buybackReserve();
        uint256 amount = bound(raw, 0, available);
        vm.prank(vault.REFUEL_SAFE());
        if (rejecting && amount > 0) vm.expectRevert(LifeForceVault.TransferFailed.selector);
        if (inference) vault.withdrawInference(amount);
        else vault.withdrawBuyback(amount);
        if (!rejecting) paid += amount;
    }

    function receiver(bool reject) public {
        rejecting = reject;
        imd.setRefuses(vault.REFUEL_SAFE(), reject);
    }

    function moveAndBurn(uint96 raw, bool burnNow) public {
        uint256 amount = bound(raw, 0, token.balanceOf(address(this)) / 100);
        token.transfer(address(vault), amount);
        if (burnNow && vault.sovrnHeld() != 0) {
            burned += vault.sovrnHeld();
            vault.burn();
        }
    }

    function unauthorizedWithdraw(uint96 raw, bool inference) public {
        vm.expectRevert(LifeForceVault.Unauthorized.selector);
        if (inference) vault.withdrawInference(raw);
        else vault.withdrawBuyback(raw);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract LifecycleInvariantTest is SystemBase {
    uint256 private constant IMD_ID = uint256(uint160(0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127));
    LifecycleHandler private handler;
    uint256 private initialSafe;

    function setUp() public {
        _systemAtPrice(false, LAUNCH_PRICE, 0);
        // All-SVO range on the SVO side of the start price; mirrored when IMD is currency1.
        (int24 lo, int24 hi) = _imdIsCurrency0() ? (int24(166200), int24(184200)) : (int24(-184200), int24(-166200));
        router.liquidity(key, ModifyLiquidityParams(lo, hi, 1e21, bytes32(0)));
        initialSafe = imd.balanceOf(vault.REFUEL_SAFE());
        handler = new LifecycleHandler(hook, router);
        token.transfer(address(handler), 300_000_000 ether);
        imd.transfer(address(handler), 1000 ether);
        // Begin every campaign with actual ERC-6909 claims from a tokens-only launch.
        handler.swap(0.0001 ether, true, true);
        assertGt(hook.claimFees(), 0);
        router.liquidity(key, ModifyLiquidityParams(-887220, 887220, 1e22, bytes32(0)));
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.swap.selector;
        selectors[1] = handler.advance.selector;
        selectors[2] = handler.redeem.selector;
        selectors[3] = handler.donate.selector;
        selectors[4] = handler.withdraw.selector;
        selectors[5] = handler.receiver.selector;
        selectors[6] = handler.moveAndBurn.selector;
        selectors[7] = handler.unauthorizedWithdraw.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
        targetSender(address(handler));
    }

    function invariant_IMDAccountingAndOnlySafeReceivesWithdrawals() public view {
        assertEq(_vaultIMD(), vault.inferenceReserve() + vault.buybackReserve());
        assertEq(_vaultIMD() + hook.claimFees() + handler.paid(), handler.fees() + handler.donations());
        assertEq(imd.balanceOf(vault.REFUEL_SAFE()) - initialSafe, handler.paid());
        assertEq(manager.balanceOf(address(hook), IMD_ID), hook.claimFees());
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(imd.balanceOf(address(router)), 0);
        assertEq(token.balanceOf(address(router)), 0);
    }

    function invariant_fixedSupplyAndEveryBurnConserved() public view {
        uint256 balances = token.balanceOf(address(this)) + token.balanceOf(ALICE) + token.balanceOf(BOB)
            + token.balanceOf(address(manager)) + token.balanceOf(address(handler)) + token.balanceOf(address(vault))
            + token.balanceOf(token.DEAD());
        assertEq(balances, 1e27);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.totalBurned(), handler.burned());
        assertEq(token.balanceOf(token.DEAD()), handler.burned());
        assertEq(token.balanceOf(address(hook)), 0);
    }

    function afterInvariant() public {
        handler.receiver(false);
        handler.redeem();
        handler.withdraw(uint96(vault.inferenceReserve()), true);
        handler.withdraw(uint96(vault.buybackReserve()), false);
        assertEq(_vaultIMD(), 0);
        assertEq(hook.claimFees(), 0);
        invariant_IMDAccountingAndOnlySafeReceivesWithdrawals();
        invariant_fixedSupplyAndEveryBurnConserved();
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract LifecycleInvariantImdHigherTest is LifecycleInvariantTest {
    function _imdIsCurrency0() internal view override returns (bool) {
        return false;
    }
}
