// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SovrnToken} from "src/SovrnToken.sol";
import {LifeForceVault} from "src/LifeForceVault.sol";
import {Guard} from "src/Interfaces.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {MockIMD} from "./mocks/MockERC20.sol";

/// @notice Independent ledgers track each category, including IMD that arrived but is not yet checkpointed.
///         Bounds come from these ledgers, never the production reserve getters.
contract VaultModelHandler is Test {
    LifeForceVault public immutable vault;
    SovrnToken public immutable token;
    address private immutable safe;
    address private immutable dead;
    MockIMD private constant IMD = MockIMD(0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127);
    uint256 public inference;
    uint256 public buyback;
    uint256 public pending; // IMD received but not yet checkpointed (split together when it is)
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
    }

    function fund(uint96 raw, bool checkpoint) external {
        uint256 amount = bound(raw, 0, 1 ether);
        funded += amount;
        assertTrue(IMD.transfer(address(vault), amount));
        pending += amount;
        if (checkpoint) {
            (inference, buyback) = modelReserves();
            pending = 0;
            vault.sync();
        }
    }

    function modelReserves() public view returns (uint256, uint256) {
        uint256 pendingBuyback = pending * 3 / 10;
        return (inference + pending - pendingBuyback, buyback + pendingBuyback);
    }

    function withdraw(uint96 raw, bool fromInference) public {
        (uint256 a, uint256 b) = modelReserves();
        uint256 amount = bound(raw, 0, fromInference ? a : b);
        vm.prank(safe);
        if (rejecting && amount != 0) vm.expectRevert(LifeForceVault.TransferFailed.selector);
        if (fromInference) vault.withdrawInference(amount);
        else vault.withdrawBuyback(amount);
        if (rejecting && amount != 0) return;
        pending = 0;
        inference = a - (fromInference ? amount : 0);
        buyback = b - (fromInference ? 0 : amount);
        if (fromInference) inferencePaid += amount;
        else buybackPaid += amount;
    }

    /// Permissionless checkpoint with nothing new, or after unsynced deposits.
    function syncOnly() external {
        (inference, buyback) = modelReserves();
        pending = 0;
        vault.sync();
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
        IMD.setRefuses(safe, reject);
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
        assertEq(IMD.balanceOf(address(vault)), a + b);
        assertEq(IMD.balanceOf(address(vault)) + inferencePaid + buybackPaid, funded);
        assertEq(IMD.balanceOf(safe), inferencePaid + buybackPaid);
        assertEq(vault.sovrnHeld(), tokensHeld);
        assertEq(token.balanceOf(address(vault)), tokensHeld);
        assertEq(token.balanceOf(dead), burned);
        assertEq(token.totalBurned(), burned);
        assertEq(token.balanceOf(address(this)) + tokensHeld + burned, 1e27);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.allowance(address(vault), safe), 0);
        assertEq(token.allowance(address(vault), address(this)), 0);
        assertEq(IMD.allowance(address(vault), safe), 0);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract VaultModelInvariantTest is Test {
    VaultModelHandler private handler;

    function setUp() public {
        vm.chainId(4663);
        deployCodeTo("MockERC20.sol:MockIMD", abi.encode(uint256(1e33)), 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127);
        SovrnToken token = new SovrnToken();
        PoolManager manager = new PoolManager(address(this));
        LifeForceVault vault = new LifeForceVault(manager, token, address(this));
        handler = new VaultModelHandler(vault, token);
        token.transfer(address(handler), token.totalSupply());
        MockIMD(0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127).transfer(address(handler), 1000 ether);
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.fund.selector;
        selectors[1] = handler.withdraw.selector;
        selectors[2] = handler.overdraw.selector;
        selectors[3] = handler.unauthorized.selector;
        selectors[4] = handler.receiver.selector;
        selectors[5] = handler.sendTokens.selector;
        selectors[6] = handler.burn.selector;
        selectors[7] = handler.syncOnly.selector;
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
        assertEq(
            MockIMD(0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127).balanceOf(address(handler.vault())),
            0,
            "all recorded funds remain withdrawable"
        );
        assertEq(handler.vault().sovrnHeld(), 0);
    }
}
