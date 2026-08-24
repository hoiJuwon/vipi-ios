import { randomBytes, timingSafeEqual } from "node:crypto";
import { chmodSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export const agentDir = process.env.PI_CODING_AGENT_DIR ?? join(homedir(), ".pi", "agent");
export const tokenPath = join(agentDir, "vipi", "token");

function persistToken(token: string): void {
  mkdirSync(dirname(tokenPath), { recursive: true, mode: 0o700 });
  const temporaryPath = `${tokenPath}.${process.pid}.tmp`;
  writeFileSync(temporaryPath, `${token}\n`, { mode: 0o600 });
  chmodSync(temporaryPath, 0o600);
  renameSync(temporaryPath, tokenPath);
  chmodSync(tokenPath, 0o600);
}

export function rotateToken(): string {
  const token = randomBytes(32).toString("base64url");
  persistToken(token);
  return token;
}

export function loadOrCreateToken(): string {
  try {
    const token = readFileSync(tokenPath, "utf8").trim();
    if (token.length >= 32) return token;
  } catch {}
  return rotateToken();
}

export function tokenMatches(expected: string, candidate: unknown): boolean {
  if (typeof candidate !== "string") return false;
  const a = Buffer.from(expected); const b = Buffer.from(candidate);
  return a.length === b.length && timingSafeEqual(a, b);
}
