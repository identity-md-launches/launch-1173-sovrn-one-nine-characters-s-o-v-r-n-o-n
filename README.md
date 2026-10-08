# SOVRN.ONE / SVO

Trading fees from the launch's SVO/ETH pool fund the inference of a voice AI. All hook fees, collected only in native ETH, go to one immutable LifeForceVault: 70% is earmarked for inference and 30% for manually buying SVO to burn. Holders receive no payouts. The vault only accounts for ETH; the Safe performs purchases outside the vault.

This project adapts IMD launch #1040, `identity-md-launches/launch-1040-og-symbol-og-the-launch-s-standard-token`, commit `c1d98b5`, under the existing MIT source licences. Changes: renamed the token and hook to SovrnToken and SovrnHook; replaced the distributor and auction with LifeForceVault; removed the collection dependency, NFT activation, rewards, auctions and team payments; consolidated deferred fees into one claim counter; updated preparation, manifest, tests and documentation. The base's fee mathematics, quote mechanism, guards, errors and five permissions are preserved. Build configuration and vendored dependencies are unchanged.

## Launch parameters

| Parameter | Value |
| --- | --- |
| Chain | Sepolia rehearsal, chain id **11155111** |
| Token contract | `SovrnToken`, no constructor arguments |
| Name / symbol | **SOVRN.ONE** / **SVO**; name is nine ASCII characters, dot at index 5 |
| Supply / decimals | **1,000,000,000** / **18**; exactly **10^27** minor units minted to the deployer |
| Currency0 / currency1 | Native ETH / SVO |
| Opening sqrtPriceX96 | **792281625142643375935439503360000** |
| Opening ratio / cap | **100,000,000 SVO per ETH** / **10 ETH** for the full supply |
| Pool LP fee / tick spacing | **12500 (1.25%)** / **60** |
| Hook flags | **8396**, hex **0x20cc**, masked to the low 14 address bits |
| Hook constructor | `(IPoolManager manager, SovrnToken token, address factory)` |
| Manifest arguments | Flat `["$poolManager", "$token", "$factory"]` |
| Child constructor | `new LifeForceVault(manager, token, address(this))` inside the hook |
| REFUEL_SAFE | **0xb1eC9d1C36974d05eb9889eBf8A150b05791E559** |
| DEAD | **0x000000000000000000000000000000000000dEaD** |

The pool LP fee is additional to the hook fee. The opening cap describes the initial ratio, not an ETH deposit requirement. The factory chooses the launch liquidity allocation. The pool block in `launch.json` is identical to the base. The vault is not a manifest deployment; discover it through `hook.vault()`.

The token has plain ERC-20 transfers and allowances, with no tax, owner, further minting, pause, blacklist or upgrade. A transfer to DEAD increases `totalBurned`; `totalSupply` remains 10^27. Burning here means transferring tokens to DEAD.

## Fees and settlement

The hook fee applies only to the single pool identified by `hook.poolKey()`. Anyone can create and fund another SVO/ETH pool without this hook; trades there pay no fee to this vault and do not use the launch buy-fee decay. SVO transfers and trading on other venues are unrestricted.

Sells always pay **3.5%**. Buys begin at **50%**, decay linearly for **3,600 seconds (60 minutes)** from the successful pool initialization timestamp, and stay at **3.5%** thereafter. At elapsed **0 / 1800 / 3600 seconds**, the buy rates are **50% / 26.75% / 3.5%**, and `decayMinutesLeft()` is **60 / 30 / 0**. Partial remaining minutes round up. Before initialization the views show 50% and 60 minutes.

The rate uses WAD **10^18**: `NORMAL_FEE = 35 * 10^15`, opening rate `5 * 10^17`, and the decreasing component is `465 * 10^15 * (3600 - elapsed) / 3600`. Integer divisions round down, preserving the base including tiny-amount rounding. Fees depend on actual AMM ETH movement, including LP fees on buys, never on SVO transfer amounts.

| Swap mode | Preserved fee handling |
| --- | --- |
| Buy, exact ETH input | Deduct `floor(requestedETH * rate / WAD)` before the AMM swap. A price-limit partial fill uses `floor(actualAMMETH * rate / (WAD - rate))`. |
| Buy, exact SVO output | Charge `floor(actualAMMETH * rate / (WAD - rate))` in ETH after the swap. |
| Sell, exact SVO input | Charge `floor(actualGrossETH * rate / WAD)` from the actual ETH output. |
| Sell, exact ETH output | Quote `floor(requestedNetETH * WAD / (WAD - rate))` gross ETH, then charge `floor(actualGrossETH * rate / WAD)`. Partial fills charge only actual output. |

For ETH-specified modes, a self-only reverting quote swap measures the actual native delta; the actual swap must match that quote. The nested swap's state, LP accounting and logs roll back. The hook uses the before-swap delta for ETH-specified fees and the after-swap delta for other modes. It does not override the LP fee. Zero swap amounts and specified amounts outside ±`type(int128).max` are rejected. Routers remain responsible for trader slippage limits and deadlines.

**100%** of each hook fee is sent directly by `PoolManager.take` to the vault when the manager's current ETH balance covers the entire fee. Otherwise the hook mints the entire fee as native ERC-6909 claims (currency id **0**) to itself and increments its single `claimFees` counter. This permits a first buy on a fresh manager seeded only with SVO, before the router settles ETH. Deferred claims enter the vault reserves only upon redemption.

Anyone can call `redeemFees()` after settlement. It opens a manager unlock, burns all recorded claims and takes the ETH directly to the immutable vault. Failure reverts the counter reset and claim burn, permitting a later retry when sufficient backing is available. A zero counter is a no-op. Redemption while the manager is already unlocked cannot open another unlock and must be retried after settlement. Multiple swaps per unlock and mixed direct/deferred payments are supported. Claim amounts sent directly to the hook by third parties are not hook fees and are not included in its counter.

Send voluntary funding to `hook.vault()`. The hook rejects ordinary ETH sends, but its inherited manager-only receive function accepts ETH routed through a third party's own manager unlock. Such ETH remains permanently in the hook, as do unsolicited ERC-6909 claims beyond `claimFees`: there is no forwarding or rescue function for either. These deposits do not divert recorded hook fees; direct fees and recorded claim redemptions still go entirely to the vault.

The vault's receive function accepts ETH without external calls. If the fee destination were to reject ETH, a direct take would revert the swap; minting claims does not call the destination, but their redemption would revert until it can accept ETH. A rejecting REFUEL_SAFE only prevents its own withdrawals; fees continue accumulating in the vault.

## Vault accounting and callers

`INFERENCE_BPS = 7000` and `BUYBACK_BPS = 3000`. Each receipt allocates `floor(value * 3000 / 10000)` to buyback and the entire remainder to inference. Thus **1 wei → 1/0**, **10 wei → 7/3**, and **11 wei → 8/3** inference/buyback. Splits apply per receipt; aggregating deferred claims can differ from splitting each fee separately by rounding dust.

`inferenceReserve()` plus `buybackReserve()` always equals the vault's ETH balance, including at external-call boundaries. ETH forced into the vault without running `receive()` is included by the reserve views using the same split on the unrecorded excess, then checkpointed on withdrawal. Such ETH has no receive event. Ordinary receipts retain their individual rounding. There is no sweep or reconciliation entry point.

| Caller | Allowed action |
| --- | --- |
| REFUEL_SAFE only | `withdrawInference(amount)` and `withdrawBuyback(amount)`, each bounded by its own reserve and paid only to REFUEL_SAFE. Both use a shared reentrancy guard, debit before payment, and revert all changes on failed payment. Zero withdrawal is a no-op payment with an event. |
| Anyone | Fund the vault with ETH, transfer SVO to it, call `burn()` or `redeemFees()`, and read all public views. |
| Anyone calling `burn()` | Send the vault's **entire** SVO balance only to DEAD. Zero balance reverts. No ETH is moved, no approvals are issued, and there is no alternate token recipient. |
| Supplied factory via PoolManager | Initialize the single native ETH/SVO pool once. It must use fee 12500, this hook, and positive tick spacing. The first spacing is bound permanently; the manifest selects 60. Deployment, initialization and initial liquidity seeding must be atomic. |
| Supplied PoolManager only | Drive `beforeInitialize`, `beforeSwap`, `afterSwap` and `unlockCallback`; callbacks also enforce their pool and operation state. |
| Hook itself only | Enter the reverting quote helper while a swap is active. |

Only REFUEL_SAFE has ongoing discretionary custody powers. The factory and manager have the protocol entry responsibilities above, not withdrawal authority. There are no owners, setters, upgrades, pause powers or other privileged recipients. The manager is supplied, never hardcoded; the vault checks its code at construction and does not otherwise use it. Token code and a nonzero hook address are checked too; the constructing hook has no runtime code yet.

Events: token `Transfer` and `Approval`; hook `PoolOpened(timestamp)`, `FeePaid(router,buy,grossETH,fee,asClaim)` and `ClaimsRedeemed(amount)`; vault `LifeForceFunded(from,amount,inference,buyback)`, `InferenceWithdrawn(amount)`, `BuybackWithdrawn(amount)` and `Burned(amount)`. Vault funding's `from` is the manager for direct takes and claim redemption. `FeePaid.router` identifies the calling router, not the trader. Views include `vault()`, `poolKey()`, `launchFeeNow()`, `decayMinutesLeft()`, `claimFees()`, both reserves, `sovrnHeld()` and token `totalBurned()`.

## Preparation and operation

The unchanged `foundry.toml` pins **Solidity 0.8.26**, **Cancun**, optimizer **200 runs**, **via_ir = true**, and **`bytecode_hash = "none"`**. Dependencies are already ordinary vendored files in `lib/`; no new packages are needed. The hook is the base's direct v4 callback implementation, with no added base-class dependency, share tokens, transient hook storage or role framework. Enabled permissions are exactly `beforeInitialize`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, `afterSwapReturnDelta`; all nine others are false.

`script/PrepareLaunch.s.sol` is an offline pure helper, with no environment reads or broadcast:

1. Supply the actual chain PoolManager, freshly deployed SovrnToken and initializing factory to `initCode(manager, token, factory)`. The token has no constructor arguments and the factory must hold its whole initial supply.
2. Hash that code and call `mine(create2Deployer, initCodeHash, firstSalt, attempts)`. The CREATE2 deployer is the actual contract executing CREATE2; it need not equal the initializing factory argument. The helper reports success, salt and predicted address. If no match is found, continue at `firstSalt + attempts` without overflowing uint256.
3. Check `predict(create2Deployer, salt, initCodeHash)` and the low 14 bits (**8396**), then have the launch system deploy exactly that code, initialize the manifest pool and seed its initial liquidity atomically. The initialization callback also prevents preinitializing an address without hook code. A previous base salt must be mined again for this new initcode.
4. Check chain id **11155111**, constructor arguments, token identity, Safe address, vault linkage and bytecode against the prepared artifacts. `launch-attestation.json` records source hashes, compiler settings, ABIs and constructor-free creation bytecode hashes; regenerate with `python3 script/attest.py`, or verify with `python3 script/attest.py --check`. Concrete hook initcode includes the actual three arguments and cannot have one universal hash or salt.

The manifest has exactly five top-level keys: `kind`, `hook`, `token`, `pool` and `notes`. The rehearsal chain id remains in its notes and in the attestation's `chainId` field; deployment tooling must enforce it. The attestation binds the manifest and every delivered test file by SHA-256, excluding disposable `test/scratch/` files.

Confirm atomic liquidity seeding in the actual factory transaction before launch. An initialized v4 pool with no liquidity permits a zero-delta swap to move its price to the caller's limit at no token or ETH cost. The unchanged hook charges zero on that zero ETH delta; deployment plus initialization alone cannot protect the opening price while liquidity is absent.

After launch, no setters or setup transactions exist. The Safe operators monitor both reserves and ETH claim backing, arrange permissionless redemption when needed, withdraw inference funds to pay for voice AI inference, and withdraw buyback funds to manually acquire SVO with appropriate trade limits. They transfer acquired SVO to the vault and anyone calls `burn()`. The contracts enforce withdrawal destination and reserve bounds; they cannot enforce what the Safe does with withdrawn ETH or schedule its purchases. Operators must confirm control of the specified Safe and its ability to receive ETH on Sepolia before launch. The supplied Safe identity is a requester parameter, not independently verified here. A mainnet variant changes the chain id and REFUEL_SAFE, then rebuilds, retests and mines new salts.

Both reserves pay the same REFUEL_SAFE, which can withdraw their combined balance without any SVO purchase or burn. The 70/30 split is accounting only. If this address is operated as a Safe, its proxy must exist on Sepolia and accept plain ETH; deployment on another chain does not establish that capability here.

## Validation and scope

Run `forge build`, `forge test` and `forge fmt --check`. All integration tests use the **real vendored v4 PoolManager deployed locally**, with a minimal settlement router; no mock manager, RPC, environment variables, FFI or filesystem cheatcodes are required. Most unit fixtures place the hook at a valid flagged address; `Launch.t.sol` additionally mines and deploys the real CREATE2 initcode and checks child deployment, opening price, factory authorization, EIP-170 and EIP-3860 size bounds.

Run `python3 -B -I -m unittest discover -s test -p test_attestation.py -v` for attestation regressions. These use the real compiled artifacts and isolated temporary delivery copies to test generation, checking, changed manifests, added or changed test files, and rejection of extra manifest keys. `RevisionBoundaries.t.sol` reproduces unsolicited deposits, recorded-fee redemption alongside stray claims, empty-pool price movement and trading without this hook.

The retained fee suite covers all four exact modes, partial fills, tiny amounts, initialization guards and comparison of quote state with an unhooked pool. New tests cover direct and claim settlement, all four modes on an empty manager in one unlock, claim retries, precise permissions, Safe withdrawal success/failure/reentrancy, reserve rounding, full burns, absence of administration and forced ETH. Stateful invariants cover trading, decay, claim redemption, donations, withdrawals, rejecting receivers and burns, ending with complete ETH withdrawal. See `test/REVIEW.md` for imported-finding reproductions and evidence.

This deliverable includes no deployment transactions. Local tests and source review do not establish live-chain readiness. Separate independent adversarial review and a chain-specific deployment rehearsal remain with the launch process; no external security certification is asserted. Static analyzers, formal verification and live forks were not run.
