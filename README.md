# Bitsocial Names (`.bso`)

The `.bso` name registry specified in [BSIP-13](https://bsips.bitsocial.net/bsip-13). BSIP-13 is the
source of truth; where this repository and the BSIP differ, the BSIP wins.

The registry is one contract, [`src/NameNFT.sol`](src/NameNFT.sol). It is a fork of
[`lucadonnoh/gwei-names`](https://github.com/lucadonnoh/gwei-names) `src/NameNFT.sol` at commit
`8e094ab343d0bfdbd9ec948594fc48f20bed6e5d`, with the changes BSIP-13 lists and no others. It has no
owner, admin, proxy, pause or upgrade path.

**Status:** not deployed on Ethereum mainnet. A test deployment is on Sepolia at
[`0x396AdD90157b398db69daDC40eCbFE0C9774B2C9`](https://sepolia.etherscan.io/address/0x396AdD90157b398db69daDC40eCbFE0C9774B2C9),
seeded with the preliminary seed list of BSIP-13 (119 entries). Its source is not verified on
Etherscan, and `FEE_RECIPIENT` has no code on Sepolia, so `sunset()` cannot be called there.

## Changes from upstream

See the whole diff with `git diff 8e094ab -- src/NameNFT.sol`.

| BSIP-13 change | In the contract |
| --- | --- |
| 1. TLD | Root node `namehash("bso")`, public as `BSO_NODE` (upstream: `GWEI_NODE`). Full names end in `.bso`. `name()` is `Bitsocial Names`, `symbol()` is `BSONAME`. |
| 2. Fees are collected | `FEE_RECIPIENT`, a constant address. `withdraw()`, callable by anyone, sends the whole balance to it. |
| 3. Seeding | `seed` and `seedBatch` register the entries of the seed list, proved against `SEED_ROOT`, to their listed owners at no fee. Until the opening, `reveal`, `registerSubdomain` and `registerSubdomainFor` revert with `NotOpen`. |
| 4. Sunset | `sunset()`, only `FEE_RECIPIENT` and only once, sets `sunsetAt` 30 days ahead. From `sunsetAt` on every state-changing function reverts with `Frozen`, except `withdraw()`. |
| 5. Minimum length | `reveal` and `seed` revert with `LabelTooShort` for a top-level label of fewer than 3 Unicode code points, and `isAvailable` returns false for one. Subdomain labels are exempt. |

There is one more change, agreed in
[BSIPs#42](https://github.com/bitsocialnet/BSIPs/issues/42) and not yet in the BSIP's text: the fee
tier of a label goes by its length in Unicode code points, as the minimum length does and as ENS's
prices do. Upstream goes by UTF-8 bytes, so that `日本語` (9 bytes) costs the 5+ price where `abc`
costs 0.05 ETH; here both cost 0.05 ETH. `reveal` and `renew` pass the code-point count to `getFee`,
whose tiers and amounts are upstream's.

Everything else is upstream's: commit-reveal, expiry, grace period and premium, subdomains, records,
and label validation.

### Details the BSIP leaves to the implementation

- `SEED_ROOT` and `SEED_COUNT` are constructor arguments stored as immutables, and `SEED_END` is set
  in the constructor to deployment time + 7 days. None can change after deployment. The source is
  therefore the same for every deployment.
- The opening is `openAt` if it is set and earlier than `SEED_END`, otherwise `SEED_END`. `openAt` is
  set, and `RegistrationOpening(openAt)` emitted, by the seed that brings `seededCount` to
  `SEED_COUNT`.
- `seedBatch` checks whether a name already has a record before anything else about the entry, and
  skips it if so, without verifying its proof. `seed` reverts with `AlreadyRegistered` instead.
- The Merkle leaf hashes the label exactly as supplied. The seed list must hold labels in the form
  the registry stores them (ASCII lowercase); the tests check this for the published list.
- Proofs are verified with solady's `MerkleProofLib`, which upstream already depends on. It accepts
  the proofs of OpenZeppelin's `StandardMerkleTree`; the tests seed the published tree with it.
- `sunset()` emits `SunsetScheduled(sunsetAt)`. A second call reverts with `AlreadySunset`.
- `makeCommitment` and `normalize` do not apply the minimum length. A commitment to a label that is
  too short is harmless, because `reveal` rejects it.
- `getFee(length)` takes a length in code points. A client must not pass the byte length of a label
  that has non-ASCII characters.

### ETH sent by mistake

The ERC-721 functions `approve`, `transferFrom` and `safeTransferFrom` are payable in solady's
`ERC721`, as they are upstream, although nothing uses the ETH. Upstream leaves such ETH locked in the
contract. Here `withdraw()` sends the whole balance to `FEE_RECIPIENT`, so ETH attached to those
calls by mistake goes there with the fees. The contract has no `receive` or `fallback`, so a plain
ETH transfer to it reverts.

## Build and test

Requires [Foundry](https://getfoundry.sh) v1.5.1. The build settings in `foundry.toml` are upstream's.

```bash
git submodule update --init --recursive
forge test
forge build --sizes   # NameNFT must stay under 24,576 bytes
```

| Tests | What they cover |
| --- | --- |
| `test/NameNFT.t.sol` | Upstream's suite. Changed only where the fork changes behaviour: the `.bso` strings, a setup that deploys with an empty seed list and starts at the opening, the test that fees are locked (now withdrawn), two tests that registered labels shorter than 3 characters, and the fee the registration fuzz test pays. |
| `test/Seeding.t.sol` | `seed`, `seedBatch` and the opening, including the published seed tree. |
| `test/Withdraw.t.sol` | `withdraw()`. |
| `test/Sunset.t.sol` | `sunset()` and the freeze. |
| `test/MinLength.t.sol` | The minimum length. |
| `test/Fees.t.sol` | The fee by characters, in `reveal` and `renew`. |
| `test/Tld.t.sol` | The `.bso` root, names and `tokenURI`. |
| `test/Scripts.t.sol` | The checks the deploy script makes on the seed tree file. |

`test/fixtures/seed-tree.json` is a copy of `assets/bsip-13/seed-tree.json` from the
[BSIPs repository](https://github.com/bitsocialnet/BSIPs/tree/master/assets/bsip-13).

## Deploy

The scripts read the seed tree, an OpenZeppelin `StandardMerkleTree` dump, from the path in
`SEED_TREE`.

```bash
export SEED_TREE=path/to/seed-tree.json

# 1. Deploy. SEED_ROOT and SEED_COUNT come from the tree. The script first checks the file and
#    seeds every entry into a throwaway registry, and refuses to deploy if any entry fails.
forge script script/Deploy.s.sol:Deploy --rpc-url <rpc> --account <keystore> --broadcast --verify

# 2. Seed every entry, 60 per transaction. Safe to run again: seeded entries are skipped.
export REGISTRY=<deployed address>
forge script script/Deploy.s.sol:Seed --rpc-url <rpc> --account <keystore> --broadcast --slow

# 3. Check that every entry is registered to its listed owner with its listed record.
forge script script/Deploy.s.sol:CheckSeeded --rpc-url <rpc>
```

Public registration opens one hour after the last entry is seeded.

`forge script` sets each transaction's gas limit from its own simulation. Sepolia (November 2026)
charges several times more gas for creating code and storage than Foundry v1.5.1 simulates: there the
deployment used 36.1M gas, not the 5.1M simulated, and a batch of 60 entries about 38M, not 9.1M.
On such a network compare with the node's `eth_estimateGas` and raise the limit with
`--gas-estimate-multiplier` (760 for `Deploy` and 440 for `Seed` worked on Sepolia). A transaction
that runs out of gas changes nothing and can be sent again. Ethereum mainnet still charged the
simulated amounts when this was written.

## Review

[`audit/bso-fork.md`](audit/bso-fork.md) records the Slither run and the review of the fork's changes.
The other files in `audit/` are upstream's audits.

## License

MIT, as upstream. See [LICENSE](LICENSE).
