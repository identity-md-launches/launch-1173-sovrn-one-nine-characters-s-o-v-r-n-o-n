// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SovrnToken} from "../src/SovrnToken.sol";
import {SovrnHook} from "../src/SovrnHook.sol";
import {LifeForceVault} from "../src/LifeForceVault.sol";
import {PoolRouter} from "./PoolRouter.sol";

abstract contract SystemBase is Test {
    PoolManager internal manager;
    SovrnToken internal token;
    SovrnHook internal hook;
    LifeForceVault internal vault;
    PoolRouter internal router;
    PoolKey internal key;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    uint160 internal constant START_PRICE = 79228162514264337593543950336000;
    uint160 internal constant LAUNCH_PRICE = 792281625142643375935439503360000;

    function _system(bool seed) internal {
        _systemAtPrice(seed, START_PRICE, 1e22);
    }

    function _systemAtPrice(bool seed, uint160 initialPrice, int256 liquidity) internal {
        vm.deal(address(this), 10000 ether);
        vm.deal(ALICE, 100 ether);
        vm.deal(BOB, 100 ether);
        manager = new PoolManager(address(this));
        // Counterfactual CREATE addresses can be prefunded on a fork; this fixture needs an empty manager.
        vm.deal(address(manager), 0);
        token = new SovrnToken();
        address at = address(uint160(0x20cc));
        deployCodeTo("SovrnHook.sol:SovrnHook", abi.encode(IPoolManager(address(manager)), token, address(this)), at);
        hook = SovrnHook(payable(at));
        vault = hook.vault();
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 12500, 60, IHooks(at));
        manager.initialize(key, initialPrice);
        router = new PoolRouter(manager);
        token.approve(address(router), type(uint256).max);
        token.transfer(ALICE, 10_000_000 ether);
        token.transfer(BOB, 10_000_000 ether);
        vm.startPrank(ALICE);
        token.approve(address(router), type(uint256).max);
        vm.stopPrank();
        if (seed) {
            router.liquidity{value: 100 ether}(key, ModifyLiquidityParams(-887220, 887220, liquidity, bytes32(0)));
        }
    }

    function _trade(bool buy, int256 amount, uint160 limit) internal returns (BalanceDelta) {
        return router.trade{value: buy ? 100 ether : 0}(key, SwapParams(buy, amount, limit));
    }

    function _trade(bool buy, int256 amount) internal returns (BalanceDelta) {
        return _trade(buy, amount, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }
    receive() external payable {}
}
