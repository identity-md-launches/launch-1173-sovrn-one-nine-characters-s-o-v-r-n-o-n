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
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @dev Pays its own manager delta; no impersonation of the manager or hook is needed.
contract UnsolicitedDepositRouter {
    IPoolManager private immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function push(address recipient, bool asClaim) external payable {
        manager.unlock(abi.encode(recipient, asClaim, msg.value));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (address recipient, bool asClaim, uint256 amount) = abi.decode(data, (address, bool, uint256));
        manager.sync(Currency.wrap(address(0)));
        manager.settle{value: amount}();
        if (asClaim) manager.mint(recipient, 0, amount);
        else manager.take(Currency.wrap(address(0)), recipient, amount);
        return "";
    }
}

/// @notice Reproductions of the documented, unchanged boundaries reported during revision.
contract RevisionBoundariesTest is SystemBase {
    using StateLibrary for IPoolManager;

    function setUp() public {
        vm.chainId(11155111);
        _systemAtPrice(false, LAUNCH_PRICE, 0);
    }

    function test_managerRoutedETHAndUnsolicitedClaimsAreNotFeeDeposits() public {
        (bool accepted,) = address(hook).call{value: 1 ether}("");
        assertFalse(accepted);
        UnsolicitedDepositRouter pusher = new UnsolicitedDepositRouter(manager);
        pusher.push{value: 1 ether}(address(hook), false);
        pusher.push{value: 1 ether}(address(hook), true);
        assertEq(address(hook).balance, 1 ether);
        assertEq(manager.balanceOf(address(hook), 0), 1 ether);
        assertEq(hook.claimFees(), 0);
        vm.prank(ALICE);
        hook.redeemFees();
        assertEq(address(hook).balance, 1 ether);
        assertEq(manager.balanceOf(address(hook), 0), 1 ether);
        assertEq(address(vault).balance, 0);
    }

    function test_strayClaimsDoNotDivertRecordedFeeRedemption() public {
        router.liquidity(key, ModifyLiquidityParams(166200, 184200, 1e21, bytes32(0)));
        _trade(true, -0.001 ether);
        assertEq(hook.claimFees(), 0.0005 ether);
        UnsolicitedDepositRouter pusher = new UnsolicitedDepositRouter(manager);
        pusher.push{value: 1 ether}(address(hook), true);
        assertEq(manager.balanceOf(address(hook), 0), 1.0005 ether);
        vm.prank(ALICE);
        hook.redeemFees();
        assertEq(hook.claimFees(), 0);
        assertEq(manager.balanceOf(address(hook), 0), 1 ether);
        assertEq(address(vault).balance, 0.0005 ether);
        assertEq(vault.inferenceReserve(), 0.00035 ether);
        assertEq(vault.buybackReserve(), 0.00015 ether);
    }

    function test_zeroLiquidityPriceMoveIsFree() public {
        uint256 aliceTokens = token.balanceOf(ALICE);
        vm.prank(ALICE);
        BalanceDelta delta = router.trade(key, SwapParams(false, -1, LAUNCH_PRICE * 10));
        assertEq(delta.amount0(), 0);
        assertEq(delta.amount1(), 0);
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(price, LAUNCH_PRICE * 10);
        assertEq(ALICE.balance, 100 ether);
        assertEq(token.balanceOf(ALICE), aliceTokens);
        assertEq(address(vault).balance, 0);
        assertEq(hook.claimFees(), 0);
    }

    function test_safeCanWithdrawBothReservesWithoutBuyingOrBurning() public {
        (bool funded,) = address(vault).call{value: 10 ether}("");
        assertTrue(funded);
        assertEq(vault.inferenceReserve(), 7 ether);
        assertEq(vault.buybackReserve(), 3 ether);
        address safe = vault.REFUEL_SAFE();
        uint256 beforeSafe = safe.balance;
        vm.startPrank(safe);
        vault.withdrawBuyback(3 ether);
        vault.withdrawInference(7 ether);
        vm.stopPrank();
        assertEq(safe.balance - beforeSafe, 10 ether);
        assertEq(address(vault).balance, 0);
        assertEq(vault.inferenceReserve() + vault.buybackReserve(), 0);
        assertEq(token.balanceOf(token.DEAD()), 0);
        assertEq(token.totalBurned(), 0);
    }

    function test_hooklessPoolBypassesTheHookFee() public {
        router.liquidity(key, ModifyLiquidityParams(166200, 184200, 1e21, bytes32(0)));
        PoolKey memory hookless = PoolKey(key.currency0, key.currency1, 3000, 60, IHooks(address(0)));
        vm.prank(ALICE);
        manager.initialize(hookless, LAUNCH_PRICE);
        router.liquidity{value: 10 ether}(hookless, ModifyLiquidityParams(-887220, 887220, 1e22, bytes32(0)));
        vm.prank(ALICE);
        BalanceDelta delta =
            router.trade{value: 1 ether}(hookless, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1));
        assertEq(delta.amount0(), -1 ether);
        assertGt(delta.amount1(), 0);
        assertEq(address(vault).balance, 0);
        assertEq(hook.claimFees(), 0);
        assertEq(hook.launchFeeNow(), 0.5e18);
        vm.prank(ALICE);
        router.trade{value: 1 ether}(key, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1));
        assertGt(address(vault).balance, 0);
    }
}
