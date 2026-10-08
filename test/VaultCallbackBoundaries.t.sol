// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LifeForceVault} from "src/LifeForceVault.sol";
import {SovrnToken} from "src/SovrnToken.sol";
import {Guard} from "src/Interfaces.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {MockIMD} from "./mocks/MockERC20.sol";

/// @dev Installed only at the specified Safe in an isolated test. Exercises a receiver (an IMD that calls back
///      on transfer) that returns IMD and burns SVO during payment, optionally reverting afterwards.
contract ReturningSafe {
    LifeForceVault private immutable vault;
    MockIMD private immutable imd;
    uint256 private immutable refund;
    bool private immutable reject;
    uint256 public observedInference;
    uint256 public observedBuyback;
    bytes public inferenceError;
    bytes public buybackError;

    constructor(LifeForceVault v, MockIMD imd_, uint256 r, bool reject_) {
        vault = v;
        imd = imd_;
        refund = r;
        reject = reject_;
    }

    function tokensReceived(uint256) external {
        observedInference = vault.inferenceReserve();
        observedBuyback = vault.buybackReserve();
        require(observedInference + observedBuyback == imd.balanceOf(address(vault)), "callback accounting");
        bool ok;
        (ok, inferenceError) = address(vault).call(abi.encodeCall(vault.withdrawInference, (1)));
        require(!ok, "inference reentry succeeded");
        (ok, buybackError) = address(vault).call(abi.encodeCall(vault.withdrawBuyback, (1)));
        require(!ok, "buyback reentry succeeded");
        require(imd.transfer(address(vault), refund), "refund refused");
        vault.burn();
        require(vault.inferenceReserve() + vault.buybackReserve() == imd.balanceOf(address(vault)), "refund accounting");
        require(!reject, "Safe rejected after callback actions");
    }
}

contract VaultCallbackBoundariesTest is Test {
    PoolManager private manager;
    SovrnToken private token;
    LifeForceVault private vault;
    MockIMD private imd;
    address private safe;
    address private constant IMD_ADDR = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;

    function setUp() public {
        vm.chainId(4663);
        // Full-range supply so a max uint256 receipt can be sent.
        deployCodeTo("MockERC20.sol:MockIMD", abi.encode(type(uint256).max), IMD_ADDR);
        imd = MockIMD(IMD_ADDR);
        manager = new PoolManager(address(this));
        token = new SovrnToken();
        vault = new LifeForceVault(manager, token, address(this));
        safe = vault.REFUEL_SAFE();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_uint256ReceiptAndExit(uint256 amount, bool inferenceFirst) public {
        _fullRangeRoundtrip(amount, inferenceFirst);
    }

    function test_maxUint256ReceiptDoesNotOverflowSplit() public {
        _fullRangeRoundtrip(type(uint256).max, true);
    }

    function _fullRangeRoundtrip(uint256 amount, bool inferenceFirst) private {
        assertTrue(imd.transfer(address(vault), amount), "receipt failed");
        // FullMath is an independent full-precision oracle, including max uint256.
        uint256 buyback = FullMath.mulDiv(amount, 3, 10);
        uint256 inference = amount - buyback;
        assertEq(vault.inferenceReserve(), inference);
        assertEq(vault.buybackReserve(), buyback);
        vm.startPrank(safe);
        if (inferenceFirst) {
            vault.withdrawInference(inference);
            vault.withdrawBuyback(buyback);
        } else {
            vault.withdrawBuyback(buyback);
            vault.withdrawInference(inference);
        }
        vm.stopPrank();
        assertEq(imd.balanceOf(safe), amount);
        assertEq(imd.balanceOf(address(vault)), 0);
        assertEq(vault.inferenceReserve() + vault.buybackReserve(), 0);
    }

    function testFuzz_refundAndBurnDuringEitherWithdrawal(bool fromInference) public {
        _fundAndPrepareSafe(false);
        vm.prank(safe);
        if (fromInference) vault.withdrawInference(1 ether);
        else vault.withdrawBuyback(1 ether);
        ReturningSafe probe = ReturningSafe(payable(safe));
        assertEq(probe.observedInference(), fromInference ? 6 ether : 7 ether);
        assertEq(probe.observedBuyback(), fromInference ? 3 ether : 2 ether);
        assertEq(probe.inferenceError(), abi.encodeWithSelector(Guard.Reentrancy.selector));
        assertEq(probe.buybackError(), abi.encodeWithSelector(Guard.Reentrancy.selector));
        assertEq(vault.inferenceReserve(), (fromInference ? 6 ether : 7 ether) + 8);
        assertEq(vault.buybackReserve(), (fromInference ? 3 ether : 2 ether) + 3);
        assertEq(imd.balanceOf(address(vault)), 9 ether + 11);
        assertEq(imd.balanceOf(safe), 1 ether - 11);
        assertEq(token.totalBurned(), 17 ether);
        assertEq(token.balanceOf(token.DEAD()), 17 ether);
        assertEq(vault.sovrnHeld(), 0);
        // Guard must be cleared when the callback finishes.
        vm.etch(safe, hex"");
        _drain();
        assertEq(imd.balanceOf(safe), 10 ether);
    }

    function testFuzz_rejectionRollsBackRefundBurnAndBothLedgers(bool fromInference) public {
        _fundAndPrepareSafe(true);
        vm.prank(safe);
        vm.expectRevert(LifeForceVault.TransferFailed.selector);
        if (fromInference) vault.withdrawInference(1 ether);
        else vault.withdrawBuyback(1 ether);
        assertEq(vault.inferenceReserve(), 7 ether);
        assertEq(vault.buybackReserve(), 3 ether);
        assertEq(imd.balanceOf(address(vault)), 10 ether);
        assertEq(imd.balanceOf(safe), 0);
        assertEq(vault.sovrnHeld(), 17 ether);
        assertEq(token.totalBurned(), 0);
        assertEq(token.balanceOf(token.DEAD()), 0);
        vm.etch(safe, hex"");
        _drain();
        vault.burn();
        assertEq(imd.balanceOf(safe), 10 ether);
        assertEq(token.totalBurned(), 17 ether);
    }

    function test_counterfactualPrefundingAndUnsolicitedDustRemainWithdrawable() public {
        bytes memory initCode =
            abi.encodePacked(type(LifeForceVault).creationCode, abi.encode(manager, token, address(this)));
        bytes32 salt = keccak256("prefunded vault fixture");
        address predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(initCode)))))
        );
        assertTrue(imd.transfer(predicted, 19));
        // CREATE2 binds the prefunded address to this exact initcode independently
        // of test-runner nonce handling and dynamic test linking.
        address deployed;
        assembly ("memory-safe") {
            deployed := create2(0, add(initCode, 32), mload(initCode), salt)
        }
        LifeForceVault fresh = LifeForceVault(payable(deployed));
        assertEq(address(fresh), predicted);
        assertEq(fresh.inferenceReserve(), 14);
        assertEq(fresh.buybackReserve(), 5);
        assertTrue(imd.transfer(address(fresh), 11));
        // Unsolicited dust must remain visible before any checkpoint.
        assertTrue(imd.transfer(address(fresh), 1));
        assertTrue(imd.transfer(address(fresh), 1));
        assertEq(fresh.inferenceReserve() + fresh.buybackReserve(), 32);
        uint256 a = fresh.inferenceReserve();
        uint256 b = fresh.buybackReserve();
        vm.startPrank(safe);
        fresh.withdrawBuyback(b);
        fresh.withdrawInference(a);
        vm.stopPrank();
        assertEq(imd.balanceOf(address(fresh)), 0);
        assertEq(imd.balanceOf(safe), 32);
    }

    function _fundAndPrepareSafe(bool reject) private {
        assertTrue(imd.transfer(address(vault), 10 ether));
        vault.sync();
        token.transfer(address(vault), 17 ether);
        vm.etch(safe, address(new ReturningSafe(vault, imd, 11, reject)).code);
        // The Safe's own IMD balance is unaffected; it re-enters from the transfer callback.
        imd.setCallback(safe);
    }

    function _drain() private {
        uint256 a = vault.inferenceReserve();
        uint256 b = vault.buybackReserve();
        vm.startPrank(safe);
        vault.withdrawInference(a);
        vault.withdrawBuyback(b);
        vm.stopPrank();
        assertEq(imd.balanceOf(address(vault)), 0);
    }
}
