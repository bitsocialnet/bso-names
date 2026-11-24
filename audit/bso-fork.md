# Review of the `.bso` fork

Reviews of the fork's changes to `src/NameNFT.sol` (`git diff 8e094ab -- src/NameNFT.sol`), made
before any deployment. The other files in this directory are upstream's audits of the code the fork
starts from. Neither review below is an external audit.

## Slither

Slither 0.11.6, default detectors, on `src/`. No finding led to a change. All results are of four kinds:

| Detector | Where | Assessment |
| --- | --- | --- |
| `timestamp` | expiry, commit age, premium, the opening, `SEED_END`, the freeze | Inherent. The periods are hours to years, far beyond what a block proposer can shift. |
| `incorrect-equality` | `whenOpen`: `openAt == 0` | Zero means "not set". `openAt` is only ever set to a time in the future. |
| `uninitialized-local` | counters in `_isTooShort` and in upstream's `_escapeJSON`, `_escapeXML` | They rely on the default value zero. |
| `shadowing-local` | parameters named `addr` in upstream's resolver functions | Upstream's code, unchanged. |

## Independent review

A review of the diff against BSIP-13, with proof-of-concept tests and 75 mutants of the contract run
against the test suite. It found no way to steal, block, pre-register or double-seed a listed name,
to bypass the pause or the freeze, or to redirect or strand ETH.

| Finding | Severity | Resolution |
| --- | --- | --- |
| `Deploy` took the root and count from the tree file without checking that the file is consistent. A wrong root would leave every listed name unprotected at `SEED_END`. | Medium | `SeedTree.load` now requires every value to hash to its leaf, one value per leaf, and the root to be the root of the values. |
| A list with an entry that cannot be seeded (two spellings of one label, a short or invalid label, a subdomain before its parent) never reaches `SEED_COUNT`, so registration opens only at `SEED_END`. This was tested only for the fixture. | Medium | `Deploy` seeds the whole tree into a throwaway registry first and refuses to deploy unless every entry registers to its owner. |
| The scripts had no tests. | Low | `test/Scripts.t.sol`. |
| `CheckSeeded` hashed the label as listed. | Low | It normalizes the label first, and its documentation says to run it right after seeding. |
| `nonReentrant` on `seed` and `seedBatch` guards nothing, since `_seed` makes no external call. | Low | Removed. |
| `isAvailable` does not reflect the pause or the freeze. | Low | Documented on the function. BSIP-13 requires only that it return false for a label that is too short. |
| Tests did not cover: the content of `tokenURI`; `computeNamehash` for a label ending in `bso` without a dot; `openAt` being set once; `withdraw()` called during a refund or from the receiver hook; `registerSubdomain` with parent 0. | Test gaps | Added in `test/Tld.t.sol`, `test/Seeding.t.sol` and `test/Withdraw.t.sol`. |

Noted, with no change:

- A label of three code points is not always three visible characters: `a` followed by two
  zero-width joiners passes. BSIP-13 accepts this; clients normalize names with ENSIP-15, and such a
  name never resolves.
- Anyone can seed the whole list as soon as the registry is deployed, which puts the opening one
  hour after deployment. The hour is enforced and `openAt` is on chain, so nobody gains from it.
- Each state-changing call reads `sunsetAt`, and `reveal` also reads `openAt`.
- The runtime bytecode is 23,208 bytes, 1,368 under the limit of 24,576.
