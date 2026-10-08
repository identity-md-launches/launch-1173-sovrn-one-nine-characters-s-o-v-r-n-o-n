// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {SystemBase} from "./SystemBase.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @dev Runs the four swap modes (IMD exact in, IMD exact out, SVO exact out, SVO exact in) in ONE unlock and settles
///      only the net amounts. Pre-fund it with IMD; it keeps whatever SVO it receives.
contract IMDBatchRouter {
    IPoolManager private immutable m;
    bool private immutable imdIsCurrency0;

    constructor(IPoolManager m_, bool imdIsCurrency0_) {
        m = m_;
        imdIsCurrency0 = imdIsCurrency0_;
    }

    function execute(PoolKey memory k) external {
        m.unlock(abi.encode(k));
    }

    function _swap(PoolKey memory k, bool buy, int256 amount) private returns (BalanceDelta) {
        bool zeroForOne = buy == imdIsCurrency0;
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        return m.swap(k, SwapParams(zeroForOne, amount, limit), "");
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(m));
        PoolKey memory k = abi.decode(data, (PoolKey));
        BalanceDelta sum = _swap(k, true, -0.001 ether);
        sum = sum + _swap(k, false, 0.0005 ether);
        sum = sum + _swap(k, true, 1000 ether);
        sum = sum + _swap(k, false, -1000 ether);
        _settle(k.currency0, sum.amount0());
        _settle(k.currency1, sum.amount1());
        return "";
    }

    function _settle(Currency c, int128 amount) private {
        if (amount < 0) {
            m.sync(c);
            require(ERC20(Currency.unwrap(c)).transfer(address(m), uint256(-int256(amount))));
            m.settle();
        } else if (amount > 0) {
            m.take(c, address(this), uint256(uint128(amount)));
        }
    }
}

contract LaunchPolicyTest is SystemBase {
    using StateLibrary for IPoolManager;

    function test_launchPriceSupportsFourModesAndFullVaultFunding() public {
        _systemAtPrice(true, LAUNCH_PRICE, 1e21);
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(price, _orient(LAUNCH_PRICE));
        BalanceDelta first = _trade(true, -0.01 ether);
        assertEq(_imdLeg(first), -0.01 ether);
        assertGt(_svoLeg(first), 0);
        assertEq(_vaultIMD(), 0.005 ether);
        assertEq(vault.inferenceReserve(), 0.0035 ether);
        assertEq(vault.buybackReserve(), 0.0015 ether);
        vm.warp(hook.openedAt() + 1 hours);
        _normalFee(true, -0.001 ether);
        _normalFee(true, 10_000 ether);
        _normalFee(false, -10_000 ether);
        _normalFee(false, 0.001 ether);
    }

    // Regression for the imported stranded-fees proof, on the specified launch price.
    function test_allFeeIMDIsReleasableAtLaunchPrice() public {
        _systemAtPrice(true, LAUNCH_PRICE, 1e21);
        vm.warp(hook.openedAt() + 1 hours);
        _trade(true, -1 ether);
        assertEq(_vaultIMD(), 0.035 ether);
        assertEq(imd.balanceOf(address(hook)), 0);
        uint256 safeBefore = imd.balanceOf(vault.REFUEL_SAFE());
        uint256 inference = vault.inferenceReserve();
        uint256 buyback = vault.buybackReserve();
        vm.startPrank(vault.REFUEL_SAFE());
        vault.withdrawInference(inference);
        vault.withdrawBuyback(buyback);
        vm.stopPrank();
        assertEq(imd.balanceOf(vault.REFUEL_SAFE()) - safeBefore, 0.035 ether);
        assertEq(_vaultIMD(), 0);
    }

    function _normalFee(bool buy, int256 amount) private {
        uint256 beforeVault = _vaultIMD();
        BalanceDelta delta = _trade(buy, amount);
        uint256 fee = _vaultIMD() - beforeVault;
        uint256 gross = buy ? uint256(-int256(_imdLeg(delta))) : uint256(int256(_imdLeg(delta))) + fee;
        assertEq(fee, gross * 350 / 10_000);
        if (buy && amount < 0) assertEq(_imdLeg(delta), amount);
        if (buy && amount > 0) assertEq(_svoLeg(delta), amount);
        if (!buy && amount < 0) assertEq(_svoLeg(delta), amount);
        if (!buy && amount > 0) assertEq(_imdLeg(delta), amount);
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(hook)), 0);
    }
}

contract LaunchPolicyImdHigherTest is LaunchPolicyTest {
    function _imdIsCurrency0() internal view override returns (bool) {
        return false;
    }
}

contract FreshManagerTest is SystemBase {
    uint256 internal constant IMD_ID = uint256(uint160(0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127));

    function setUp() public {
        _systemAtPrice(false, LAUNCH_PRICE, 0);
        // All SVO at opening (range sits on the SVO side of the start price). This is a test range, not a launch
        // liquidity allocation. With IMD as currency1 the whole tick picture is mirrored.
        (int24 lo, int24 hi) = _imdIsCurrency0() ? (int24(166200), int24(184200)) : (int24(-184200), int24(-166200));
        router.liquidity(key, ModifyLiquidityParams(lo, hi, 1e21, bytes32(0)));
        assertEq(imd.balanceOf(address(manager)), 0);
    }

    function testFuzz_firstBuyClaimsBothExactModesAndDecay(bool exactInput, uint16 elapsed) public {
        vm.warp(hook.openedAt() + bound(elapsed, 0, 7200));
        BalanceDelta first = _trade(true, exactInput ? -int256(0.01 ether) : int256(10_000 ether));
        uint256 gross = uint256(-int256(_imdLeg(first)));
        uint256 expected = gross * hook.launchFeeNow() / 1e18;
        assertGt(expected, 0);
        assertEq(hook.claimFees(), expected);
        assertEq(manager.balanceOf(address(hook), IMD_ID), expected);
        assertEq(_vaultIMD(), 0);
        assertEq(vault.inferenceReserve() + vault.buybackReserve(), 0);
        vm.prank(BOB);
        hook.redeemFees();
        assertEq(hook.claimFees(), 0);
        assertEq(manager.balanceOf(address(hook), IMD_ID), 0);
        assertEq(_vaultIMD(), expected);
        assertEq(vault.buybackReserve(), expected * 3000 / 10000);
        assertEq(vault.inferenceReserve(), expected - expected * 3000 / 10000);
        hook.redeemFees();
        assertEq(_vaultIMD(), expected);
        assertEq(imd.balanceOf(address(hook)), 0);
    }

    function test_allFourModesMintClaimsInOneUnlockOnEmptyManager() public {
        vm.warp(hook.openedAt() + 1 hours);
        IMDBatchRouter batch = new IMDBatchRouter(manager, _imdIsCurrency0());
        imd.transfer(address(batch), 10 ether);
        vm.recordLogs();
        batch.execute(key);
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
        assertGt(token.balanceOf(address(batch)), 0);
        assertEq(hook.claimFees(), fees);
        assertEq(manager.balanceOf(address(hook), IMD_ID), fees);
        assertEq(_vaultIMD(), 0);
        hook.redeemFees();
        assertEq(_vaultIMD(), fees);
        assertEq(hook.claimFees(), 0);
        assertEq(manager.balanceOf(address(hook), IMD_ID), 0);
        assertEq(imd.balanceOf(address(hook)), 0);
    }

    function test_claimAndDirectFeesMixedBeforeRedemption() public {
        _trade(true, -0.001 ether);
        assertEq(hook.claimFees(), 0.0005 ether);
        _trade(true, -0.001 ether);
        assertEq(hook.claimFees(), 0.0005 ether);
        assertEq(_vaultIMD(), 0.0005 ether);
        vm.prank(ALICE);
        hook.redeemFees();
        assertEq(hook.claimFees(), 0);
        assertEq(_vaultIMD(), 0.001 ether);
        assertEq(vault.inferenceReserve(), 0.0007 ether);
        assertEq(vault.buybackReserve(), 0.0003 ether);
    }

    function test_failedRedemptionRestoresClaimsAndCanRetry() public {
        _trade(true, -0.001 ether);
        uint256 backing = imd.balanceOf(address(manager));
        vm.prank(address(manager));
        imd.transfer(address(0xBEEF), backing);
        vm.expectRevert();
        hook.redeemFees();
        assertEq(hook.claimFees(), 0.0005 ether);
        assertEq(manager.balanceOf(address(hook), IMD_ID), 0.0005 ether);
        vm.prank(address(0xBEEF));
        imd.transfer(address(manager), backing);
        hook.redeemFees();
        assertEq(_vaultIMD(), 0.0005 ether);
        assertEq(hook.claimFees(), 0);
    }

    function test_refusingVaultDoesNotBlockClaimMintButRedemptionReverts() public {
        imd.setRefuses(address(vault), true);
        _trade(true, -0.001 ether);
        assertEq(hook.claimFees(), 0.0005 ether);
        vm.expectRevert();
        hook.redeemFees();
        assertEq(hook.claimFees(), 0.0005 ether);
        assertEq(manager.balanceOf(address(hook), IMD_ID), 0.0005 ether);
        imd.setRefuses(address(vault), false);
        hook.redeemFees();
        assertEq(_vaultIMD(), 0.0005 ether);
        assertEq(hook.claimFees(), 0);
    }
}

contract FreshManagerImdHigherTest is FreshManagerTest {
    function _imdIsCurrency0() internal view override returns (bool) {
        return false;
    }
}
