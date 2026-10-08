// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LifeForceVault} from "src/LifeForceVault.sol";
import {SovrnToken} from "src/SovrnToken.sol";
import {Guard} from "src/Interfaces.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {ForceETH} from "./Vault.t.sol";

/// @dev Installed only at the specified Safe in an isolated test. Exercises a receiver
///      that returns ETH and burns SVO during payment, optionally reverting afterwards.
contract ReturningSafe {
    LifeForceVault private immutable vault;
    uint256 private immutable refund;
    bool private immutable reject;
    uint256 public observedInference;
    uint256 public observedBuyback;
    bytes public inferenceError;
    bytes public buybackError;

    constructor(LifeForceVault v, uint256 r, bool reject_) {
        vault = v;
        refund = r;
        reject = reject_;
    }

    receive() external payable {
        observedInference = vault.inferenceReserve();
        observedBuyback = vault.buybackReserve();
        require(observedInference + observedBuyback == address(vault).balance, "callback accounting");
        bool ok;
        (ok, inferenceError) = address(vault).call(abi.encodeCall(vault.withdrawInference, (1)));
        require(!ok, "inference reentry succeeded");
        (ok, buybackError) = address(vault).call(abi.encodeCall(vault.withdrawBuyback, (1)));
        require(!ok, "buyback reentry succeeded");
        (ok,) = address(vault).call{value: refund}("");
        require(ok, "refund refused");
        vault.burn();
        require(vault.inferenceReserve() + vault.buybackReserve() == address(vault).balance, "refund accounting");
        require(!reject, "Safe rejected after callback actions");
    }
}

contract VaultCallbackBoundariesTest is Test {
    PoolManager private manager;
    SovrnToken private token;
    LifeForceVault private vault;
    address private safe;

    function setUp() public {
        vm.chainId(11155111);
        manager = new PoolManager(address(this));
        token = new SovrnToken();
        vault = new LifeForceVault(manager, token, address(this));
        safe = vault.REFUEL_SAFE();
        vm.deal(safe, 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_uint256ReceiptAndExit(uint256 amount, bool inferenceFirst) public {
        _fullRangeRoundtrip(amount, inferenceFirst);
    }

    function test_maxUint256ReceiptDoesNotOverflowSplit() public {
        _fullRangeRoundtrip(type(uint256).max, true);
    }

    function _fullRangeRoundtrip(uint256 amount, bool inferenceFirst) private {
        vm.deal(address(this), amount);
        (bool ok,) = address(vault).call{value: amount}("");
        assertTrue(ok, "receipt overflowed");
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
        assertEq(safe.balance, amount);
        assertEq(address(vault).balance, 0);
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
        assertEq(address(vault).balance, 9 ether + 11);
        assertEq(safe.balance, 1 ether - 11);
        assertEq(token.totalBurned(), 17 ether);
        assertEq(token.balanceOf(token.DEAD()), 17 ether);
        assertEq(vault.sovrnHeld(), 0);
        // Guard must be cleared when the callback finishes.
        vm.etch(safe, hex"");
        _drain();
        assertEq(safe.balance, 10 ether);
    }

    function testFuzz_rejectionRollsBackRefundBurnAndBothLedgers(bool fromInference) public {
        _fundAndPrepareSafe(true);
        vm.prank(safe);
        vm.expectRevert(Guard.ETHSendFailed.selector);
        if (fromInference) vault.withdrawInference(1 ether);
        else vault.withdrawBuyback(1 ether);
        assertEq(vault.inferenceReserve(), 7 ether);
        assertEq(vault.buybackReserve(), 3 ether);
        assertEq(address(vault).balance, 10 ether);
        assertEq(safe.balance, 0);
        assertEq(vault.sovrnHeld(), 17 ether);
        assertEq(token.totalBurned(), 0);
        assertEq(token.balanceOf(token.DEAD()), 0);
        vm.etch(safe, hex"");
        _drain();
        vault.burn();
        assertEq(safe.balance, 10 ether);
        assertEq(token.totalBurned(), 17 ether);
    }

    function test_counterfactualPrefundingAndForcedDustRemainWithdrawable() public {
        vm.deal(address(this), 100);
        bytes memory initCode =
            abi.encodePacked(type(LifeForceVault).creationCode, abi.encode(manager, token, address(this)));
        bytes32 salt = keccak256("prefunded vault fixture");
        address predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(initCode)))))
        );
        (bool ok,) = predicted.call{value: 19}("");
        assertTrue(ok);
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
        (ok,) = address(fresh).call{value: 11}("");
        assertTrue(ok);
        // Two forced dust transfers must remain visible before any checkpoint.
        new ForceETH{value: 1}(payable(address(fresh)));
        new ForceETH{value: 1}(payable(address(fresh)));
        assertEq(fresh.inferenceReserve() + fresh.buybackReserve(), 32);
        uint256 a = fresh.inferenceReserve();
        uint256 b = fresh.buybackReserve();
        vm.startPrank(safe);
        fresh.withdrawBuyback(b);
        fresh.withdrawInference(a);
        vm.stopPrank();
        assertEq(address(fresh).balance, 0);
        assertEq(safe.balance, 32);
    }

    function _fundAndPrepareSafe(bool reject) private {
        vm.deal(address(this), 10 ether);
        (bool ok,) = address(vault).call{value: 10 ether}("");
        assertTrue(ok);
        token.transfer(address(vault), 17 ether);
        vm.etch(safe, address(new ReturningSafe(vault, 11, reject)).code);
    }

    function _drain() private {
        uint256 a = vault.inferenceReserve();
        uint256 b = vault.buybackReserve();
        vm.startPrank(safe);
        vault.withdrawInference(a);
        vault.withdrawBuyback(b);
        vm.stopPrank();
        assertEq(address(vault).balance, 0);
    }
}
