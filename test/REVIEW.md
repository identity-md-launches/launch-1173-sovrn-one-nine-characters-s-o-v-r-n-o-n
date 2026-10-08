# Implementation and regression notes

Scope: SovrnToken, SovrnHook, LifeForceVault, HookFlags, the retained Guard, PrepareLaunch, launch metadata, and local integration tests. The requested behavior takes precedence over the imported base's distribution model. No dependency or build configuration changes were made.

## Imported findings reproduced before adaptation

| Finding id prefix | Evidence on the arriving tree | Delivered regression |
| --- | --- | --- |
| `7f399222d173` | Executed the supplied proof on a real local PoolManager at chain id 11155111 with no code at the collection address. It failed its final assertion with **25000000000000000 != 0**; prior assertions established the 0.025 ETH allocation, zero weight, backlog and three reverting access paths. | `LaunchPolicyTest.test_allFeeETHIsReleasableOnLaunchChain`: the entire 0.035 ETH goes to the vault and the Safe withdraws it. Fresh-manager tests cover deferred settlement too. |
| `97c5c734540c` | The base's `test_decayAndSurplus` passed, observing the unauthorized-for-this-brief 0.01 ETH team payment on a 1 ETH opening buy. Source traced direct payment, retained credit and deferred claims to the same fixed address. | `HookTest.test_decayAndFullFeeToVault` checks the full 0.5 ETH in the vault, split 0.35/0.15; four-mode balance and invariant checks conserve all fees there. Removed team address, events, credit, counters and payment methods. |
| `62d4c4fd4953` | The base's `test_supplyPlainTransferAllowanceAndBurn` passed with the old identity. Source and manifest had the same old name and symbol. | `TokenTest` checks exactly SOVRN.ONE / SVO, nine bytes and the dot; `script/attest.py` cross-checks the manifest. Token implementation otherwise unchanged. |
| `a22971544a0d` | The base's `test_policyPriceTokensOnlyLaunchClaimsAndExit` passed, proving holder ETH payment after activation and NFT custody movement. Source traced the internal swap in ETH activation. | Removed both child contracts, their interfaces, mocks and exclusively obsolete tests. Vault authorization, full burn and token-destination tests replace that lifecycle. Only the Safe can withdraw vault ETH. |
| `e6f4ad884062` | Read the arriving manifest: old contract names, mainnet policy and collection/team notes. Pool block and three flat arguments were valid. | Regenerated metadata; `script/attest.py` verifies exact names, flat arguments, five permissions and unchanged pool block; vault is absent from manifest deployment entries. |
| `1332d2af4454` | Read the arriving helper's old hook creation-code reference and flag name. Its real CREATE2 deployment test passed for the old code, demonstrating what the old salts encode. | `LaunchTest` mines the new hook initcode, deploys to its prediction, checks flags 8396 and vault linkage, then initializes through the factory. Helper now names SovrnHook and SOVRN_FLAGS. |
| `42d58e13b8bc` | Read the README: credited the base but used the wrong proposed name and omitted the specified numbers and privileges. | Replaced with the exact identity, launch numbers, authority table, fee formulas, accounting, preparation and operating responsibilities. Manifest and attestation checks bind deployment metadata. |

All seven adaptation findings reproduce locally or by direct inspection as indicated. The high-severity finding's live Sepolia `eth_getCode` observation was **not independently repeated**; the local reproduction explicitly establishes the stated no-code precondition. No chain availability claim is inferred from it. The proposed remedy removes that dependency completely.

## Preserved behavior and new checks

An exact source comparison before formatting confirmed that `getHookPermissions`, `poolKey`, `_checkPool`, `beforeInitialize`, `launchFeeNow`, `decayMinutesLeft`, `beforeSwap`, `_quote`, `quoteNative`, `_abs` and `_int128`, plus all `afterSwap` fee arithmetic before the destination block, are unchanged from the base. Token changes are limited to contract/file name and the two identity strings.

Existing still-applicable fee, partial-fill, tiny-rounding, pool-state rollback, unauthorized callback, amount-bound, batch-unlock, token-transfer and real CREATE2 tests are retained and adapted to the new destination. Removed tests depended exclusively on deleted NFT, reward, auction or team behavior. Their fork dependencies are also gone.

| Suite | Evidence |
| --- | --- |
| `Token.t.sol` | Supply, identity, plain transfers, finite/infinite allowances, zero address and insufficient balance failures, DEAD accounting. |
| `Hook.t.sol`, `AdversarialFees.t.sol`, `ReviewRegression.t.sol` | All four modes, partial limits, tiny inputs, 1000-run settlement fuzzing, decay boundaries, quote state matching a reference AMM and four swaps in one unlock. |
| `LaunchPolicy.t.sol` | Required opening price and chain, fee release, tokens-only first buys, direct plus pending claims, all four modes producing claims before settlement, failed redemption rollback and retry. |
| `Vault.t.sol` | Per-receipt rounding, 1000-run funding/withdrawal roundtrips, matching-reserve bounds, rejecting Safe rollback, same-function and cross-function reentrancy refusal, full SVO burns, forbidden alternate destinations and forced ETH. |
| `Security.t.sol` | Exactly five permissions, all initial key fields, second initialization, constructor checks, bad flags, direct fee rejection rollback, hook busy guard, absent administrative selectors and opcode scan. |
| `Launch.t.sol` | Real CREATE2 mining and deployment, child constructor linkage, factory-only initialization, 100,000,000 SVO/ETH price, 10 ETH initial cap and code-size limits. |
| `LifecycleInvariants.t.sol` | 256 sequences of 96 calls per property, with unexpected reverts failing the run. Real swaps, initial claims, ETH donation, forced ETH, redemption, Safe withdrawals, receiver rejection, SVO transfers and burns. Each sequence ends with all fee ETH redeemed and withdrawn. |

The invariant oracle checks vault balance equals both reserves; vault ETH plus pending claims plus Safe payments equals fee events plus donations; native manager claims equal the one hook counter; actual Safe receipts equal successful withdrawals; all tracked token balances sum to 10^27; and each recorded burn equals the DEAD balance and totalBurned. Fee events are independently checked against swap direction, rate and actual AMM/trader balances in the settlement tests. The real manager enforces settlement of all deltas at unlock completion.

## Source review boundaries

Reviewed applicable arithmetic, access-control, external-call, state-coupling, boundary and value-flow failure modes from the supplied references. Verified that callback entry is manager-only, initialization binds one factory/pool, fee deltas collect only the computed native fee, quote state reverts, claims cannot redirect payments, both withdrawals use the same guard and debit before calling the Safe, and burn calls only the fixed token and DEAD recipient. Vault reserve views include forced ETH because receive-only storage cannot account for an EVM balance increase that bypasses code.

The Safe is the sole discretionary custodian, intentionally trusted to spend the two withdrawn categories as described. The launch factory must supply the genuine PoolManager and SovrnToken and initialize atomically on the intended chain. Manager/token code checks prove code presence, not identity. No on-chain chain-id restriction was added, preserving the base hook behavior; launch tooling must enforce the attested chain.

The supplied protected suites were read; their environment-injected deployment wrapper was not copied into tests. Equivalent local permission, initialization, token supply and runtime opcode checks use the real compiled contracts without environment injection. This work does not claim an independent review, formal proof, live fork result, Slither/Mythril run or review of all vendored internals. Independent launch review and deployment rehearsal remain outstanding.

## Revision evidence

This revision leaves all production Solidity and the CREATE2 preparation helper unchanged. The arriving checkout differs from the independent review's snapshot: its manifest still had a top-level `chainId`, `python3 -I script/attest.py --check` passed, all delivery hashes matched, and every test file present was recorded. The six extra test files named by the reviewer were absent from this checkout. No claim is made that those missing files were recovered.

The schema incompatibility did reproduce: supplying the reported five-key manifest to the unchanged script raised `AssertionError` at line 27 before artifact processing. All four new Python regression tests failed before the fix. The script now requires exactly `kind`, `hook`, `token`, `pool`, `notes`; the manifest's extra key was removed, and the rehearsal chain remains 11155111 in the attestation and manifest notes. The record is regenerated from this delivered tree. Python regressions verify generation/checking against actual compiler artifacts, reject changed manifests without modifying the record, reject added or changed test evidence until regeneration, and reject extra manifest keys.

`RevisionBoundaries.t.sol` uses the real vendored PoolManager on local chain id 11155111 at the requested opening price:

| Finding id prefix | Reproduction and disposition |
| --- | --- |
| `df83383c15e3` | An ordinary ETH send fails; a third party settling its own manager delta can send 1 ETH or mint 1 ETH of native claims to the hook. With no recorded fees, redemption leaves both there. A separate first-buy test confirms that a 0.0005 ETH recorded fee is fully redeemed to the vault alongside 1 ETH of unsolicited claims, leaving only the unsolicited claims behind. Adopted the reviewer's documentation option: README explicitly discloses permanent stranding and directs voluntary funding to the vault. No change to receive or claim accounting. |
| `d3c40d8222ad` | An unprivileged swap against the empty initialized pool moves sqrtPriceX96 to ten times its opening value with both deltas zero, unchanged trader balances and no hook fee. This is inherited behavior; README and manifest preparation now explicitly require atomic deployment, initialization and liquidity seeding. The actual factory transaction remains a deployment responsibility. |
| `94244a7418cf` | Funding 10 ETH produces reserves 7/3; the Safe withdraws all 10 ETH while DEAD and totalBurned remain zero. Existing vault tests also verify unauthorized callers, reserve bounds and a rejecting Safe. This is the requested custody model. README makes the combined withdrawal power and Sepolia Safe-proxy assumption explicit. Live Safe code, control and receiver behavior remain unverified. |
| `1177879b8741` | An unprivileged account initializes a hookless pool, then a funded 1 ETH buy produces SVO but no vault fee, while a buy on the hooked pool at the same timestamp pays the vault. README now limits the fee description to `poolKey()` and discloses trading elsewhere without the hook fee or launch decay. |

The seven imported OG findings describe contracts and metadata already replaced in the accepted round. Their current regression suites still cover full fee release, direct/deferred settlement, exact token identity, absence of legacy privileged paths, reserve withdrawals and burns, and real CREATE2 deployment. `.imd-responses.json` provides an individual disposition for all twelve finding ids, distinguishing the historical findings from this revision's reproductions.
