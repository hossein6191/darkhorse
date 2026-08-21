# 🐎 DarkHorse — hidden-side prediction markets

**A parimutuel YES/NO prediction market where bet *sizes* are public but bet *sides* are
encrypted on-chain with [Inco Lightning](https://docs.inco.org) until resolution.**

## The problem

On transparent prediction markets everyone watches where the smart money goes.
Whales signal, crowds bandwagon, and copy-traders free-ride on informed bets —
distorting the odds long before the market closes.

## The fix

DarkHorse keeps the *direction* of every bet — and the running YES/NO pool totals —
encrypted on-chain using Inco's TEE-based confidential compute:

| Data                          | Visibility                                              |
| ----------------------------- | ------------------------------------------------------- |
| Bettor address, stake, pot    | public (it's native ETH — public by nature)             |
| Each bettor's side (YES/NO)   | 🔒 encrypted `ebool` — only the bettor can decrypt it   |
| Running YES / NO pool totals  | 🔒 encrypted `euint256` — nobody can read them, ever    |
| Winning-side total            | revealed at settlement via on-chain-verified attestation |
| A bettor's own result         | revealed only if *they* opt in by claiming              |

No running tally to probe, nothing to front-run, nothing to copy.

## How it works (the confidential mechanics)

```
bet:      side = newEbool(ciphertext)            // 1 Inco fee, side never plaintext
          totalYes += side.select(stake, 0)      // encrypted fold — no branching
          totalNo  += side.select(0, stake)

resolve:  e.reveal(winningTotalHandle)           // aggregate only, irreversible

settle:   attestedReveal(handle) off-chain  →  submitWinningTotal(attestation)
          on-chain: isValidDecryptionAttestation + handle-match check

claim:    winStake = side.select(stake, 0)       // 0 if you lost
          attestedReveal → claim(attestation)    // payout = winStake × pot ÷ winningTotal
```

Every attestation is verified with `inco.incoVerifier().isValidDecryptionAttestation`
**and** bound to the exact expected handle — a valid attestation for a different
handle is rejected (`HandleMismatch`).

Honest framing: Inco is **TEE-based (Intel TDX), not FHE and not ZK**. Reveals are
covalidator-signed attestations verified on-chain — players trust the enclave and
its attestation, not zero-knowledge math.

## Repo layout

```
contracts/DarkHorse.sol   the market contract (~330 lines, fully commented)
test/DarkHorse.t.sol      14 Foundry tests — lifecycle, privacy, attack paths
script/Deploy.s.sol       Base Sepolia deploy script
frontend/                 Vite + React + viem + @inco/lightning-js dApp
```

## Run the tests (no Docker needed)

Tests run against `IncoTest`, which mocks the whole Inco stack inside Foundry:

```bash
bun install
forge test -vv
```

14 tests cover:
- full lifecycle: 3 bettors → encrypted totals → resolve → attested settle → pro-rata claims
- privacy: third parties can NOT decrypt a bettor's side or the running totals
- attack paths: wrong-handle attestation, stolen attestation, double claim — all revert
- guardrails: one bet per address, no bets after close, resolver-only resolve, refunds

## Deploy to Base Sepolia

```bash
export BASE_SEPOLIA_RPC_URL=https://sepolia.base.org
forge script script/Deploy.s.sol --rpc-url base_sepolia --broadcast \
  --private-key $PRIVATE_KEY_BASE_SEPOLIA
```

## Run the frontend

```bash
cd frontend
cp .env.example .env.local     # set VITE_DARKHORSE_ADDRESS to your deployment
bun install
bun run dev
```

Flow in the UI: **Create market → Bet YES/NO (side encrypted client-side) →
🔐 Peek my side (private attested decrypt — only you) → Resolve → Settle
(attested reveal of the aggregate) → Claim payout.**

## Design notes / known trade-offs

- **Stake sizes are public by design.** ETH amounts can't be hidden without a
  confidential token rail; hiding only the side is exactly what kills
  copy-trading while keeping payments simple. (A cERC-20 rail is the natural v2.)
- **Claiming reveals your own result** — after the market is over, opt-in only.
  Losers never have to reveal anything (there is nothing to claim).
- **One bet per address per market** keeps the encrypted fold simple and blocks
  side-averaging probes.
- **Resolver is the market creator** (oracle-of-trust for v1); swap in any oracle
  by changing one address.
- If the winning side is empty, `winningTotal == 0` unlocks full refunds; a
  canceled market refunds everyone too.

## Versions

`@inco/lightning@1.0.2` · `@inco/lightning-js@1.0.2` · solc 0.8.30 (cancun) ·
Foundry 1.7.1 · viem 2.39.3

---

Built with the [Inco agent skill](https://docs.inco.org/build-with-ai) + Inco MCP.
