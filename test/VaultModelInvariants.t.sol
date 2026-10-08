// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SovrnToken} from "src/SovrnToken.sol";
import {LifeForceVault} from "src/LifeForceVault.sol";
import {Guard} from "src/Interfaces.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {ForceETH} from "./Vault.t.sol";
import {RejectETH} from "./Hook.t.sol";

/// @notice Independent ledgers track each category, including pending forced ETH.
///         Bounds come from these ledgers, never the production reserve getters.
contract VaultModelHandler is Test {
    LifeForceVault public immutable vault;
    SovrnToken public immutable token;
    address private immutable safe;
    address private immutable dead;
    address private immutable rejectingReceiver;
    uint256 public inference;
    uint256 public buyback;
    uint256 public forced;
    uint256 public funded;
    uint256 public inferencePaid;
    uint256 public buybackPaid;
    uint256 public tokensHeld;
    uint256 public burned;
    bool public rejecting;

    constructor(LifeForceVault v, SovrnToken t) {
        vault = v;
        token = t;
        safe = v.REFUEL_SAFE();
        dead = t.DEAD();
        rejectingReceiver = address(new RejectETH());
    }

    function fund(uint96 raw, bool force) external {
        uint256 amount = bound(raw, 0, 1 ether);
        funded += amount;
        if (force) {
            forced += amount;
            new ForceETH{value: amount}(payable(address(vault)));
        } else {
            (bool ok,) = address(vault).call{value: amount}("");
            assertTrue(ok);
            buyback += amount * 3 / 10;
            inference += amount - amount * 3 / 10;
        }
    }

    function modelReserves() public view returns (uint256, uint256) {
        uint256 forcedBuyback = forced * 3 / 10;
        return (inference + forced - forcedBuyback, buyback + forcedBuyback);
    }

    function withdraw(uint96 raw, bool fromInference) public {
        (uint256 a, uint256 b) = modelReserves();
        uint256 amount = bound(raw, 0, fromInference ? a : b);
        vm.prank(safe);
        if (rejecting && amount != 0) vm.expectRevert(Guard.ETHSendFailed.selector);
        if (fromInference) vault.withdrawInference(amount);
        else vault.withdrawBuyback(amount);
        if (rejecting && amount != 0) return;
        forced = 0;
        inference = a - (fromInference ? amount : 0);
        buyback = b - (fromInference ? 0 : amount);
        if (fromInference) inferencePaid += amount;
        else buybackPaid += amount;
    }

    function overdraw(uint96 raw, bool fromInference) external {
        (uint256 a, uint256 b) = modelReserves();
        uint256 amount = (fromInference ? a : b) + bound(raw, 1, 1 ether);
        vm.prank(safe);
        vm.expectRevert(LifeForceVault.InvalidAmount.selector);
        if (fromInference) vault.withdrawInference(amount);
        else vault.withdrawBuyback(amount);
    }

    function unauthorized(uint256 amount, bool fromInference) external {
        // Safe tx.origin must not authorize a different msg.sender.
        vm.prank(address(this), safe);
        vm.expectRevert(LifeForceVault.Unauthorized.selector);
        if (fromInference) vault.withdrawInference(amount);
        else vault.withdrawBuyback(amount);
    }

    function receiver(bool reject) public {
        rejecting = reject;
        vm.etch(safe, reject ? rejectingReceiver.code : bytes(""));
    }

    function sendTokens(uint96 raw) external {
        uint256 amount = bound(raw, 0, 1e27 - tokensHeld - burned);
        assertTrue(token.transfer(address(vault), amount));
        tokensHeld += amount;
    }

    function burn() public {
        if (tokensHeld == 0) vm.expectRevert(LifeForceVault.InvalidAmount.selector);
        vault.burn();
        burned += tokensHeld;
        tokensHeld = 0;
    }

    function assertModel() public view {
        (uint256 a, uint256 b) = modelReserves();
        assertEq(vault.inferenceReserve(), a, "inference category drift");
        assertEq(vault.buybackReserve(), b, "buyback category drift");
        assertEq(address(vault).balance, a + b);
        assertEq(address(vault).balance + inferencePaid + buybackPaid, funded);
        assertEq(safe.balance, inferencePaid + buybackPaid);
        assertEq(vault.sovrnHeld(), tokensHeld);
        assertEq(token.balanceOf(address(vault)), tokensHeld);
        assertEq(token.balanceOf(dead), burned);
        assertEq(token.totalBurned(), burned);
        assertEq(token.balanceOf(address(this)) + tokensHeld + burned, 1e27);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.allowance(address(vault), safe), 0);
        assertEq(token.allowance(address(vault), address(this)), 0);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract VaultModelInvariantTest is Test {
    VaultModelHandler private handler;

    function setUp() public {
        vm.chainId(11155111);
        SovrnToken token = new SovrnToken();
        PoolManager manager = new PoolManager(address(this));
        LifeForceVault vault = new LifeForceVault(manager, token, address(this));
        handler = new VaultModelHandler(vault, token);
        token.transfer(address(handler), token.totalSupply());
        vm.deal(address(handler), 1000 ether);
        vm.deal(vault.REFUEL_SAFE(), 0);
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.fund.selector;
        selectors[1] = handler.withdraw.selector;
        selectors[2] = handler.overdraw.selector;
        selectors[3] = handler.unauthorized.selector;
        selectors[4] = handler.receiver.selector;
        selectors[5] = handler.sendTokens.selector;
        selectors[6] = handler.burn.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_independentReserveAndAssetLedgers() public view {
        handler.assertModel();
    }

    function afterInvariant() public {
        handler.receiver(false);
        (uint256 a, uint256 b) = handler.modelReserves();
        handler.withdraw(uint96(a), true);
        handler.withdraw(uint96(b), false);
        handler.burn();
        handler.assertModel();
        assertEq(address(handler.vault()).balance, 0, "all recorded funds remain withdrawable");
        assertEq(handler.vault().sovrnHeld(), 0);
    }
}
