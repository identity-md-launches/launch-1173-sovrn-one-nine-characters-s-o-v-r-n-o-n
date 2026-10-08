// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SystemBase} from "./SystemBase.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {MockIMD} from "./mocks/MockERC20.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @dev Pays its own manager delta (in IMD); no impersonation of the manager or hook is needed.
contract UnsolicitedDepositRouter {
    IPoolManager private immutable manager;
    address private immutable imd;

    constructor(IPoolManager manager_, address imd_) {
        manager = manager_;
        imd = imd_;
    }

    /// @dev The caller must have transferred `amount` IMD to this contract first.
    function push(address recipient, bool asClaim, uint256 amount) external {
        manager.unlock(abi.encode(recipient, asClaim, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (address recipient, bool asClaim, uint256 amount) = abi.decode(data, (address, bool, uint256));
        manager.sync(Currency.wrap(imd));
        require(MockIMD(imd).transfer(address(manager), amount));
        manager.settle();
        if (asClaim) manager.mint(recipient, uint256(uint160(imd)), amount);
        else manager.take(Currency.wrap(imd), recipient, amount);
        return "";
    }
}

/// @notice Reproductions of the documented, unchanged boundaries reported during revision.
contract RevisionBoundariesTest is SystemBase {
    using StateLibrary for IPoolManager;

    uint256 internal immutable IMD_ID = uint256(uint160(IMD_ADDR));

    function setUp() public {
        _systemAtPrice(false, LAUNCH_PRICE, 0);
    }

    /// @dev Single-sided SVO range just below the start price (mirrored when IMD is currency1).
    function _addRange() private {
        (int24 lo, int24 hi) = _imdIsCurrency0() ? (int24(166200), int24(184200)) : (int24(-184200), int24(-166200));
        router.liquidity(key, ModifyLiquidityParams(lo, hi, 1e21, bytes32(0)));
    }

    function _pusher(uint256 amount) private returns (UnsolicitedDepositRouter p) {
        p = new UnsolicitedDepositRouter(manager, IMD_ADDR);
        imd.transfer(address(p), amount);
    }

    /// @dev Replaces "hook receive() rejects non-manager ETH": the hook has no receive/fallback at all, so a
    ///      plain ETH call (or any unknown selector) reverts. Manager-routed IMD and unsolicited claims are
    ///      still not fee deposits.
    function test_managerRoutedIMDAndUnsolicitedClaimsAreNotFeeDeposits() public {
        (bool accepted,) = address(hook).call{value: 1 ether}("");
        assertFalse(accepted);
        (accepted,) = address(hook).call(hex"12345678");
        assertFalse(accepted);
        (accepted,) = address(vault).call{value: 1 ether}("");
        assertFalse(accepted);
        assertEq(address(hook).balance, 0);
        assertEq(address(vault).balance, 0);
        UnsolicitedDepositRouter pusher = _pusher(2 ether);
        pusher.push(address(hook), false, 1 ether);
        pusher.push(address(hook), true, 1 ether);
        assertEq(imd.balanceOf(address(hook)), 1 ether);
        assertEq(manager.balanceOf(address(hook), IMD_ID), 1 ether);
        assertEq(hook.claimFees(), 0);
        vm.prank(ALICE);
        hook.redeemFees();
        assertEq(imd.balanceOf(address(hook)), 1 ether);
        assertEq(manager.balanceOf(address(hook), IMD_ID), 1 ether);
        assertEq(_vaultIMD(), 0);
    }

    function test_strayClaimsDoNotDivertRecordedFeeRedemption() public {
        _addRange();
        _trade(true, -0.001 ether);
        assertEq(hook.claimFees(), 0.0005 ether);
        UnsolicitedDepositRouter pusher = _pusher(1 ether);
        pusher.push(address(hook), true, 1 ether);
        assertEq(manager.balanceOf(address(hook), IMD_ID), 1.0005 ether);
        vm.prank(ALICE);
        hook.redeemFees();
        assertEq(hook.claimFees(), 0);
        assertEq(manager.balanceOf(address(hook), IMD_ID), 1 ether);
        assertEq(_vaultIMD(), 0.0005 ether);
        assertEq(vault.inferenceReserve(), 0.00035 ether);
        assertEq(vault.buybackReserve(), 0.00015 ether);
    }

    function test_zeroLiquidityPriceMoveIsFree() public {
        uint256 aliceTokens = token.balanceOf(ALICE);
        vm.prank(ALICE);
        BalanceDelta delta = _trade(false, -1, LAUNCH_PRICE * 10);
        assertEq(delta.amount0(), 0);
        assertEq(delta.amount1(), 0);
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(price, _orient(LAUNCH_PRICE * 10));
        assertEq(imd.balanceOf(ALICE), 100 ether);
        assertEq(token.balanceOf(ALICE), aliceTokens);
        assertEq(_vaultIMD(), 0);
        assertEq(hook.claimFees(), 0);
    }

    function test_safeCanWithdrawBothReservesWithoutBuyingOrBurning() public {
        imd.transfer(address(vault), 10 ether);
        assertEq(vault.inferenceReserve(), 7 ether);
        assertEq(vault.buybackReserve(), 3 ether);
        address safe = vault.REFUEL_SAFE();
        uint256 beforeSafe = imd.balanceOf(safe);
        vm.startPrank(safe);
        vault.withdrawBuyback(3 ether);
        vault.withdrawInference(7 ether);
        vm.stopPrank();
        assertEq(imd.balanceOf(safe) - beforeSafe, 10 ether);
        assertEq(_vaultIMD(), 0);
        assertEq(vault.inferenceReserve() + vault.buybackReserve(), 0);
        assertEq(token.balanceOf(token.DEAD()), 0);
        assertEq(token.totalBurned(), 0);
    }

    function test_hooklessPoolBypassesTheHookFee() public {
        _addRange();
        PoolKey memory hookless = PoolKey(key.currency0, key.currency1, 3000, 60, IHooks(address(0)));
        vm.prank(ALICE);
        manager.initialize(hookless, _orient(LAUNCH_PRICE));
        router.liquidity(hookless, ModifyLiquidityParams(-887220, 887220, 1e22, bytes32(0)));
        bool zeroForOne = _imdIsCurrency0();
        vm.prank(ALICE);
        BalanceDelta delta =
            router.trade(hookless, SwapParams(zeroForOne, -1 ether, _orient(TickMath.MIN_SQRT_PRICE + 1)));
        assertEq(_imdLeg(delta), -1 ether);
        assertGt(_svoLeg(delta), 0);
        assertEq(_vaultIMD(), 0);
        assertEq(hook.claimFees(), 0);
        assertEq(hook.launchFeeNow(), 0.5e18);
        vm.prank(ALICE);
        _trade(true, -1 ether);
        assertGt(_vaultIMD(), 0);
    }
}

/// @dev Same suite with IMD as the higher address (currency1).
contract RevisionBoundariesReversedTest is RevisionBoundariesTest {
    function _imdIsCurrency0() internal view override returns (bool) {
        return false;
    }
}
