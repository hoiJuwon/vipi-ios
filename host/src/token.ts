import { randomBytes, timingSafeEqual } from "node:crypto";
import { chmodSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export const agentDir = process.env.PI_CODING_AGENT_DIR ?? join(homedir(), ".pi", "agent");
export const tokenPath = join(agentDir, "vipi", "token");

export function loadOrCreateToken(): string {
  try { return readFileSync(tokenPath, "utf8").trim(); } catch {}
  const token = randomBytes(32).toString("base64url");
  mkdirSync(dirname(tokenPath), { recursive: true, mode: 0o700 });
  writeFileSync(tokenPath, `${token}\n`, { mode: 0o600 });
  chmodSync(tokenPath, 0o600);
  return token;
}

export function tokenMatches(expected: string, candidate: unknown): boolean {
  if (typeof candidate !== "string") return false;
  const a = Buffer.from(expected); const b = Buffer.from(candidate);
  return a.length === b.length && timingSafeEqual(a, b);
}
