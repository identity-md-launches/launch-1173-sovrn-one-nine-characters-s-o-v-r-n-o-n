// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

contract PoolRouter {
    IPoolManager public immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }

    function trade(PoolKey memory key, SwapParams memory params) external payable returns (BalanceDelta d) {
        d = abi.decode(manager.unlock(abi.encode(msg.sender, key, true, abi.encode(params))), (BalanceDelta));
        _refund();
    }

    function liquidity(PoolKey memory key, ModifyLiquidityParams memory params)
        external
        payable
        returns (BalanceDelta d)
    {
        d = abi.decode(manager.unlock(abi.encode(msg.sender, key, false, abi.encode(params))), (BalanceDelta));
        _refund();
    }

    function _refund() private {
        if (address(this).balance > 0) {
            (bool ok,) = msg.sender.call{value: address(this).balance}("");
            require(ok);
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (address payer, PoolKey memory key, bool swap, bytes memory params) =
            abi.decode(data, (address, PoolKey, bool, bytes));
        BalanceDelta d;
        if (swap) d = manager.swap(key, abi.decode(params, (SwapParams)), "");
        else (d,) = manager.modifyLiquidity(key, abi.decode(params, (ModifyLiquidityParams)), "");
        _settle(key.currency0, payer, d.amount0());
        _settle(key.currency1, payer, d.amount1());
        return abi.encode(d);
    }

    /// @dev Both pool currencies are ERC-20 (SVO and IMD): pull what the pool is owed from the payer.
    function _settle(Currency c, address payer, int128 amount) private {
        if (amount < 0) {
            uint256 debt = uint256(-int256(amount));
            manager.sync(c);
            require(ERC20(Currency.unwrap(c)).transferFrom(payer, address(manager), debt));
            manager.settle();
        } else if (amount > 0) {
            manager.take(c, payer, uint256(uint128(amount)));
        }
    }
    receive() external payable {}
}
