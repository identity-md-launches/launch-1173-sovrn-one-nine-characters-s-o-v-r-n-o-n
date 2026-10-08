// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {SystemBase} from "./SystemBase.sol";
import {SovrnHook} from "../src/SovrnHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract ReviewBatchRouter {
    IPoolManager private immutable m;

    constructor(IPoolManager m_) {
        m = m_;
    }

    function execute(PoolKey memory k) external payable {
        m.unlock(abi.encode(k));
        (bool ok,) = msg.sender.call{value: address(this).balance}("");
        require(ok);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(m));
        PoolKey memory k = abi.decode(data, (PoolKey));
        BalanceDelta sum = m.swap(k, SwapParams(true, -0.001 ether, TickMath.MIN_SQRT_PRICE + 1), "");
        sum = sum + m.swap(k, SwapParams(false, 0.0005 ether, TickMath.MAX_SQRT_PRICE - 1), "");
        sum = sum + m.swap(k, SwapParams(true, 1000 ether, TickMath.MIN_SQRT_PRICE + 1), "");
        sum = sum + m.swap(k, SwapParams(false, -1000 ether, TickMath.MAX_SQRT_PRICE - 1), "");
        require(sum.amount0() < 0 && sum.amount1() > 0);
        m.sync(k.currency0);
        m.settle{value: uint256(-int256(sum.amount0()))}();
        m.take(k.currency1, address(this), uint256(int256(sum.amount1())));
        return "";
    }
    receive() external payable {}
}

contract ReviewRegressionTest is SystemBase {
    function setUp() public {
        _system(true);
        vm.warp(hook.openedAt() + 1 hours);
    }

    function testFuzz_tinyFeeRounding(uint16 raw, bool buy, bool exactInput, uint16 elapsed) public {
        vm.warp(hook.openedAt() + uint256(elapsed));
        uint256 amount = bound(uint256(raw), 1, 65535);
        int256 specified = int256(buy == exactInput ? amount : amount * 1000000);
        if (exactInput) specified = -specified;
        uint256 beforeVault = address(vault).balance;
        BalanceDelta d = _trade(buy, specified);
        uint256 paidFee = address(vault).balance - beforeVault;
        uint256 gross = buy ? uint256(-int256(d.amount0())) : uint256(int256(d.amount0())) + paidFee;
        uint256 fee = gross * (buy ? hook.launchFeeNow() : hook.NORMAL_FEE()) / 1e18;
        assertEq(paidFee, fee);
        if (buy && exactInput) assertEq(gross, amount);
        if (!buy && !exactInput) assertEq(uint256(int256(d.amount0())), amount);
    }

    function test_fourModesInSameUnlockSettleNetAmounts() public {
        ReviewBatchRouter batch = new ReviewBatchRouter(manager);
        batch.execute{value: 10 ether}(key);
        assertGt(token.balanceOf(address(batch)), 0);
        assertEq(address(batch).balance, 0);
        assertEq(address(hook).balance, 0);
    }
}
