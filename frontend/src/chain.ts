import {
  createPublicClient,
  createWalletClient,
  custom,
  http,
  defineChain,
  type WalletClient,
} from "viem";
import { baseSepolia } from "viem/chains";
import { Lightning } from "@inco/lightning-js/lite";

export const DARKHORSE_ADDRESS = (import.meta.env.VITE_DARKHORSE_ADDRESS ??
  "0x0000000000000000000000000000000000000000") as `0x${string}`;

const NETWORK = (import.meta.env.VITE_NETWORK ?? "baseSepolia") as
  | "baseSepolia"
  | "local";

export const localAnvil = defineChain({
  id: 31337,
  name: "Local Inco Node",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["http://localhost:8545"] } },
});

export const chain = NETWORK === "local" ? localAnvil : baseSepolia;

export const publicClient = createPublicClient({
  chain,
  transport: http(),
});

export function getWalletClient(account?: `0x${string}`): WalletClient {
  const eth = (window as any).ethereum;
  if (!eth) throw new Error("No injected wallet found — install MetaMask.");
  return createWalletClient({ chain, transport: custom(eth), account });
}

export type Zap = Awaited<ReturnType<typeof Lightning.baseSepoliaTestnet>>;

let zapPromise: Promise<Zap> | null = null;

/** Lazily initialize the Inco SDK for the configured network. */
export function getZap(): Promise<Zap> {
  if (!zapPromise) {
    zapPromise = (
      NETWORK === "local"
        ? Lightning.localNode("mainnet")
        : Lightning.baseSepoliaTestnet()
    ) as unknown as Promise<Zap>;
  }
  return zapPromise;
}
