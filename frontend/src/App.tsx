import { useCallback, useEffect, useState } from "react";
import { formatEther, parseEther } from "viem";
import { darkHorseAbi } from "./abi";
import {
  DARKHORSE_ADDRESS,
  chain,
  getWalletClient,
  publicClient,
} from "./chain";
import { attestDecrypt, attestReveal, encryptSide, getIncoFee } from "./inco";

const OUTCOME = ["Open", "YES won", "NO won", "Canceled"] as const;

interface MarketView {
  id: number;
  question: string;
  resolver: `0x${string}`;
  closeTime: number;
  outcome: number;
  pot: bigint;
  totalYesHandle: `0x${string}`;
  totalNoHandle: `0x${string}`;
  winningTotal: bigint;
  totalsSubmitted: boolean;
  myStake: bigint;
  myClaimed: boolean;
}

export default function App() {
  const [account, setAccount] = useState<`0x${string}` | null>(null);
  const [markets, setMarkets] = useState<MarketView[]>([]);
  const [busy, setBusy] = useState<string | null>(null);
  const [status, setStatus] = useState<string>("");
  const [question, setQuestion] = useState("");
  const [closeMins, setCloseMins] = useState("60");

  const connect = useCallback(async () => {
    const wc = getWalletClient();
    const [addr] = await wc.requestAddresses();
    try {
      await wc.switchChain({ id: chain.id });
    } catch {
      /* wallet may not know the chain; user can add it manually */
    }
    setAccount(addr);
  }, []);

  const loadMarkets = useCallback(async () => {
    if (DARKHORSE_ADDRESS === "0x0000000000000000000000000000000000000000") {
      setStatus(
        "Contract not configured — deploy DarkHorse and set VITE_DARKHORSE_ADDRESS in frontend/.env.local"
      );
      return;
    }
    const count = (await publicClient.readContract({
      address: DARKHORSE_ADDRESS,
      abi: darkHorseAbi,
      functionName: "marketCount",
    })) as bigint;

    const list: MarketView[] = [];
    for (let i = 0; i < Number(count); i++) {
      const m = (await publicClient.readContract({
        address: DARKHORSE_ADDRESS,
        abi: darkHorseAbi,
        functionName: "getMarket",
        args: [BigInt(i)],
      })) as readonly [
        string,
        `0x${string}`,
        bigint,
        number,
        bigint,
        `0x${string}`,
        `0x${string}`,
        bigint,
        boolean,
      ];

      let myStake = 0n;
      let myClaimed = false;
      if (account) {
        myStake = (await publicClient.readContract({
          address: DARKHORSE_ADDRESS,
          abi: darkHorseAbi,
          functionName: "stakeOf",
          args: [BigInt(i), account],
        })) as bigint;
        myClaimed = (await publicClient.readContract({
          address: DARKHORSE_ADDRESS,
          abi: darkHorseAbi,
          functionName: "claimed",
          args: [BigInt(i), account],
        })) as boolean;
      }

      list.push({
        id: i,
        question: m[0],
        resolver: m[1],
        closeTime: Number(m[2]),
        outcome: m[3],
        pot: m[4],
        totalYesHandle: m[5],
        totalNoHandle: m[6],
        winningTotal: m[7],
        totalsSubmitted: m[8],
        myStake,
        myClaimed,
      });
    }
    setMarkets(list.reverse());
  }, [account]);

  useEffect(() => {
    loadMarkets().catch((e) => setStatus(`Load failed: ${e.message}`));
  }, [loadMarkets]);

  async function run(label: string, fn: () => Promise<void>) {
    setBusy(label);
    setStatus("");
    try {
      await fn();
      await loadMarkets();
      setStatus(`✓ ${label} done`);
    } catch (e: any) {
      setStatus(`✗ ${label}: ${e.shortMessage ?? e.message}`);
    } finally {
      setBusy(null);
    }
  }

  async function write(functionName: string, args: any[], value?: bigint) {
    if (!account) throw new Error("Connect wallet first");
    const wc = getWalletClient();
    const { request } = await publicClient.simulateContract({
      account,
      address: DARKHORSE_ADDRESS,
      abi: darkHorseAbi,
      functionName: functionName as any,
      args: args as any,
      value,
    });
    const hash = await wc.writeContract(request);
    await publicClient.waitForTransactionReceipt({ hash });
  }

  const createMarket = () =>
    run("Create market", async () => {
      const closeTime = Math.floor(Date.now() / 1000) + Number(closeMins) * 60;
      await write("createMarket", [question, BigInt(closeTime)]);
      setQuestion("");
    });

  const bet = (m: MarketView, side: boolean, amount: string) =>
    run(`Bet ${side ? "YES" : "NO"}`, async () => {
      if (!account) throw new Error("Connect wallet first");
      const stake = parseEther(amount);
      const fee = await getIncoFee();
      const ct = await encryptSide(side, account);
      await write("placeBet", [BigInt(m.id), ct], stake + fee);
    });

  const resolveMarket = (m: MarketView, yesWon: boolean) =>
    run(`Resolve ${yesWon ? "YES" : "NO"}`, () =>
      write("resolve", [BigInt(m.id), yesWon])
    );

  const settle = (m: MarketView) =>
    run("Settle totals", async () => {
      const winningHandle =
        m.outcome === 1 ? m.totalYesHandle : m.totalNoHandle;
      const att = await attestReveal(winningHandle);
      await write("submitWinningTotal", [
        BigInt(m.id),
        att.decryption,
        att.signatures,
      ]);
    });

  const claimPayout = (m: MarketView) =>
    run("Claim", async () => {
      if (!account) throw new Error("Connect wallet first");
      // Step 1: prepare (derives + reveals your winStake handle).
      const existing = (await publicClient.readContract({
        address: DARKHORSE_ADDRESS,
        abi: darkHorseAbi,
        functionName: "winStakeHandleOf",
        args: [BigInt(m.id), account],
      })) as `0x${string}`;
      if (existing === `0x${"0".repeat(64)}`) {
        await write("prepareClaim", [BigInt(m.id)]);
      }
      const handle = (await publicClient.readContract({
        address: DARKHORSE_ADDRESS,
        abi: darkHorseAbi,
        functionName: "winStakeHandleOf",
        args: [BigInt(m.id), account],
      })) as `0x${string}`;
      // Step 2: fetch attestation and settle on-chain.
      const att = await attestReveal(handle);
      await write("claim", [BigInt(m.id), att.decryption, att.signatures]);
      const win = att.plaintext as bigint;
      setStatus(
        win > 0n
          ? `🎉 You won! Winning stake ${formatEther(win)} ETH — payout sent.`
          : "No winnings on this one."
      );
    });

  const refund = (m: MarketView) =>
    run("Refund", () => write("refund", [BigInt(m.id)]));

  const peekMySide = (m: MarketView) =>
    run("Peek my side", async () => {
      if (!account) throw new Error("Connect wallet first");
      const handle = (await publicClient.readContract({
        address: DARKHORSE_ADDRESS,
        abi: darkHorseAbi,
        functionName: "sideHandleOf",
        args: [BigInt(m.id), account],
      })) as `0x${string}`;
      const wc = getWalletClient(account);
      const v = await attestDecrypt(wc, handle);
      const isYes = typeof v === "boolean" ? v : v !== 0n;
      setStatus(
        `🔐 Your private side on “${m.question}”: ${isYes ? "YES" : "NO"} (only you can see this)`
      );
    });

  const now = Math.floor(Date.now() / 1000);

  return (
    <div className="wrap">
      <header>
        <h1>
          🐎 DarkHorse
          <span className="tag">hidden-side prediction markets · Inco Lightning</span>
        </h1>
        {account ? (
          <span className="addr">
            {account.slice(0, 6)}…{account.slice(-4)}
          </span>
        ) : (
          <button className="primary" onClick={connect}>
            Connect wallet
          </button>
        )}
      </header>

      <p className="pitch">
        Bet sizes are public — bet <b>sides are encrypted on-chain</b> until the
        market resolves. Nobody can see which way the pool leans, so nobody can
        copy-trade the smart money. Aggregate totals open at settlement via a
        covalidator attestation verified on-chain.
      </p>

      {status && <div className="status">{status}</div>}

      <section className="card">
        <h2>Create a market</h2>
        <div className="row">
          <input
            placeholder="Will X happen by Y?"
            value={question}
            onChange={(e) => setQuestion(e.target.value)}
          />
          <input
            className="mins"
            type="number"
            min="1"
            value={closeMins}
            onChange={(e) => setCloseMins(e.target.value)}
            title="Betting window (minutes)"
          />
          <span className="hint">min</span>
          <button
            className="primary"
            disabled={!account || !question || busy !== null}
            onClick={createMarket}
          >
            Create
          </button>
        </div>
      </section>

      {markets.map((m) => (
        <MarketCard
          key={m.id}
          m={m}
          now={now}
          account={account}
          busy={busy}
          onBet={bet}
          onResolve={resolveMarket}
          onSettle={settle}
          onClaim={claimPayout}
          onRefund={refund}
          onPeek={peekMySide}
        />
      ))}

      {markets.length === 0 && (
        <p className="empty">No markets yet — create the first one.</p>
      )}

      <footer>
        Built on{" "}
        <a href="https://docs.inco.org" target="_blank" rel="noreferrer">
          Inco Lightning
        </a>{" "}
        (TEE attestations, not ZK) · contract-verified handle binding on every
        attestation
      </footer>
    </div>
  );
}

function MarketCard(props: {
  m: MarketView;
  now: number;
  account: `0x${string}` | null;
  busy: string | null;
  onBet: (m: MarketView, side: boolean, amount: string) => void;
  onResolve: (m: MarketView, yesWon: boolean) => void;
  onSettle: (m: MarketView) => void;
  onClaim: (m: MarketView) => void;
  onRefund: (m: MarketView) => void;
  onPeek: (m: MarketView) => void;
}) {
  const { m, now, account, busy } = props;
  const [amount, setAmount] = useState("0.001");

  const open = m.outcome === 0 && now < m.closeTime;
  const awaitingResolve = m.outcome === 0 && now >= m.closeTime;
  const resolved = m.outcome === 1 || m.outcome === 2;
  const isResolver =
    account && account.toLowerCase() === m.resolver.toLowerCase();
  const refundable =
    m.outcome === 3 || (m.totalsSubmitted && m.winningTotal === 0n);
  const iBet = m.myStake > 0n;

  return (
    <section className="card market">
      <div className="mhead">
        <h3>{m.question}</h3>
        <span className={`badge o${m.outcome} ${open ? "open" : ""}`}>
          {open
            ? "Open"
            : awaitingResolve
              ? "Awaiting resolve"
              : OUTCOME[m.outcome]}
        </span>
      </div>

      <div className="stats">
        <span>
          Pot <b>{formatEther(m.pot)} ETH</b>
        </span>
        <span>
          YES pool <b className="secret">{resolved && m.totalsSubmitted
            ? m.outcome === 1
              ? `${formatEther(m.winningTotal)} ETH`
              : `${formatEther(m.pot - m.winningTotal)} ETH`
            : "🔒 encrypted"}</b>
        </span>
        <span>
          NO pool <b className="secret">{resolved && m.totalsSubmitted
            ? m.outcome === 2
              ? `${formatEther(m.winningTotal)} ETH`
              : `${formatEther(m.pot - m.winningTotal)} ETH`
            : "🔒 encrypted"}</b>
        </span>
        {iBet && (
          <span>
            My stake <b>{formatEther(m.myStake)} ETH</b>
          </span>
        )}
      </div>

      <div className="actions">
        {open && !iBet && (
          <>
            <input
              className="amt"
              value={amount}
              onChange={(e) => setAmount(e.target.value)}
            />
            <span className="hint">ETH</span>
            <button
              className="yes"
              disabled={!account || busy !== null}
              onClick={() => props.onBet(m, true, amount)}
            >
              Bet YES
            </button>
            <button
              className="no"
              disabled={!account || busy !== null}
              onClick={() => props.onBet(m, false, amount)}
            >
              Bet NO
            </button>
          </>
        )}

        {iBet && m.outcome === 0 && (
          <button disabled={busy !== null} onClick={() => props.onPeek(m)}>
            🔐 Peek my side
          </button>
        )}

        {awaitingResolve && isResolver && (
          <>
            <button
              className="yes"
              disabled={busy !== null}
              onClick={() => props.onResolve(m, true)}
            >
              Resolve YES
            </button>
            <button
              className="no"
              disabled={busy !== null}
              onClick={() => props.onResolve(m, false)}
            >
              Resolve NO
            </button>
          </>
        )}

        {resolved && !m.totalsSubmitted && (
          <button
            className="primary"
            disabled={busy !== null}
            onClick={() => props.onSettle(m)}
          >
            Settle (post attested total)
          </button>
        )}

        {resolved && m.totalsSubmitted && !refundable && iBet && !m.myClaimed && (
          <button
            className="primary"
            disabled={busy !== null}
            onClick={() => props.onClaim(m)}
          >
            Claim payout
          </button>
        )}

        {refundable && iBet && !m.myClaimed && (
          <button
            className="primary"
            disabled={busy !== null}
            onClick={() => props.onRefund(m)}
          >
            Refund stake
          </button>
        )}

        {iBet && m.myClaimed && <span className="hint">✓ settled</span>}
      </div>
    </section>
  );
}
