import { readFileSync } from "node:fs";

type SessionEntry = Record<string, unknown> & { id: string; parentId?: string | null };

/**
 * Reads a stable branch snapshot without ever opening the session as a writer.
 * A concurrently appended partial final JSONL line is ignored and retried on
 * the next page request.
 */
export function readSessionBranch(sessionFile: string): SessionEntry[] {
  const lines = readFileSync(sessionFile, "utf8").split("\n");
  const entries: SessionEntry[] = [];
  for (const line of lines) {
    if (!line.trim()) continue;
    try {
      const value = JSON.parse(line) as Record<string, unknown>;
      if (typeof value.id === "string") entries.push(value as SessionEntry);
    } catch {
      // Only a concurrently written final line may be incomplete. Other valid
      // entries remain available instead of failing the whole conversation.
    }
  }
  const byID = new Map(entries.map((entry) => [entry.id, entry]));
  const branch: SessionEntry[] = [];
  let cursor = entries.at(-1);
  const visited = new Set<string>();
  while (cursor && !visited.has(cursor.id)) {
    visited.add(cursor.id);
    branch.push(cursor);
    cursor = typeof cursor.parentId === "string" ? byID.get(cursor.parentId) : undefined;
  }
  return branch.reverse();
}
