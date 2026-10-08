// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {SystemBase} from "./SystemBase.sol";
import {SovrnHook} from "../src/SovrnHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @dev Runs all four swap modes in one unlock and settles only the net. Fund it with IMD before `execute`;
///      whatever IMD is left over is returned to the caller (the old flow sent and refunded native ETH).
contract ReviewBatchRouter {
    address private constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    IPoolManager private immutable m;

    constructor(IPoolManager m_) {
        m = m_;
    }

    function execute(PoolKey memory k) external {
        m.unlock(abi.encode(k));
        uint256 left = ERC20(IMD).balanceOf(address(this));
        if (left > 0) require(ERC20(IMD).transfer(msg.sender, left));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(m));
        PoolKey memory k = abi.decode(data, (PoolKey));
        // A BUY pays IMD in: zeroForOne exactly when IMD is currency0.
        bool buyZero = Currency.unwrap(k.currency0) == IMD;
        uint160 down = TickMath.MIN_SQRT_PRICE + 1;
        uint160 up = TickMath.MAX_SQRT_PRICE - 1;
        BalanceDelta sum = m.swap(k, SwapParams(buyZero, -0.001 ether, buyZero ? down : up), "");
        sum = sum + m.swap(k, SwapParams(!buyZero, 0.0005 ether, buyZero ? up : down), "");
        sum = sum + m.swap(k, SwapParams(buyZero, 1000 ether, buyZero ? down : up), "");
        sum = sum + m.swap(k, SwapParams(!buyZero, -1000 ether, buyZero ? up : down), "");
        int128 imdNet = buyZero ? sum.amount0() : sum.amount1();
        int128 svoNet = buyZero ? sum.amount1() : sum.amount0();
        require(imdNet < 0 && svoNet > 0);
        Currency imdC = buyZero ? k.currency0 : k.currency1;
        Currency svoC = buyZero ? k.currency1 : k.currency0;
        m.sync(imdC);
        require(ERC20(IMD).transfer(address(m), uint256(-int256(imdNet))));
        m.settle();
        m.take(svoC, address(this), uint256(int256(svoNet)));
        return "";
    }
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
        uint256 beforeVault = _vaultIMD();
        BalanceDelta d = _trade(buy, specified);
        uint256 paidFee = _vaultIMD() - beforeVault;
        uint256 gross = buy ? uint256(-int256(_imdLeg(d))) : uint256(int256(_imdLeg(d))) + paidFee;
        uint256 fee = gross * (buy ? hook.launchFeeNow() : hook.NORMAL_FEE()) / 1e18;
        assertEq(paidFee, fee);
        if (buy && exactInput) assertEq(gross, amount);
        if (!buy && !exactInput) assertEq(uint256(int256(_imdLeg(d))), amount);
    }

    function test_fourModesInSameUnlockSettleNetAmounts() public {
        ReviewBatchRouter batch = new ReviewBatchRouter(manager);
        imd.transfer(address(batch), 10 ether);
        batch.execute(key);
        assertGt(token.balanceOf(address(batch)), 0);
        assertEq(imd.balanceOf(address(batch)), 0);
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(hook)), 0);
    }
}

contract ReviewRegressionReversedTest is ReviewRegressionTest {
    function _imdIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
