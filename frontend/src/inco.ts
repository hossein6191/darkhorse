import { handleTypes, type HexString } from "@inco/lightning-js";
import { pad, toHex, bytesToHex, type WalletClient } from "viem";
import { publicClient, getZap, DARKHORSE_ADDRESS } from "./chain";
import { getFeeAbi } from "./abi";

/** Current Inco executor fee (one ciphertext ingest = one fee). */
export async function getIncoFee(): Promise<bigint> {
  const zap = await getZap();
  return (await publicClient.readContract({
    address: zap.executorAddress as `0x${string}`,
    abi: getFeeAbi,
    functionName: "getFee",
  })) as bigint;
}

/** Encrypt a YES/NO side as an ebool ciphertext bound to (user, DarkHorse). */
export async function encryptSide(
  side: boolean,
  accountAddress: `0x${string}`
): Promise<HexString> {
  const zap = await getZap();
  return zap.encrypt(side, {
    accountAddress,
    dappAddress: DARKHORSE_ADDRESS,
    handleType: handleTypes.ebool,
  });
}

export interface Attestation {
  decryption: { handle: `0x${string}`; value: `0x${string}` };
  signatures: `0x${string}`[];
  plaintext: bigint | boolean;
}

/** Attested reveal of a publicly revealed handle (no wallet signature). */
export async function attestReveal(handle: `0x${string}`): Promise<Attestation> {
  const zap = await getZap();
  const results = await zap.attestedReveal([handle as HexString]);
  const r = results[0];
  return {
    decryption: {
      handle: r.handle as `0x${string}`,
      value: pad(toHex(r.plaintext.value as bigint), { size: 32 }),
    },
    signatures: r.covalidatorSignatures.map((s: Uint8Array) => bytesToHex(s)),
    plaintext: r.plaintext.value,
  };
}

/** Private attested decrypt (owner-only) — used to peek your own side. */
export async function attestDecrypt(
  walletClient: WalletClient,
  handle: `0x${string}`
): Promise<bigint | boolean> {
  const zap = await getZap();
  const results = await zap.attestedDecrypt(walletClient as any, [handle as HexString]);
  return results[0].plaintext.value;
}
