import { closeSync, openSync, readFileSync, readSync, statSync } from "node:fs";

type SessionEntry = Record<string, unknown> & { id: string; parentId?: string | null };

/**
 * Reads a stable branch snapshot without ever opening the session as a writer.
 * A concurrently appended partial final JSONL line is ignored and retried on
 * the next page request.
 */
export function readSessionEntryPage(
  sessionFile: string,
  options: { endOffset?: number; limit?: number; byteBudget?: number } = {},
): { entries: SessionEntry[]; cursorOffset: number; hasMore: boolean } {
  const size = statSync(sessionFile).size;
  const endOffset = Math.max(0, Math.min(size, options.endOffset ?? size));
  const byteBudget = options.byteBudget ?? 8 * 1024 * 1024;
  const startOffset = Math.max(0, endOffset - byteBudget);
  const length = endOffset - startOffset;
  if (length <= 0) return { entries: [], cursorOffset: 0, hasMore: false };
  const descriptor = openSync(sessionFile, "r");
  try {
    const buffer = Buffer.allocUnsafe(length);
    readSync(descriptor, buffer, 0, length, startOffset);
    const indexed: Array<{ entry: SessionEntry; offset: number }> = [];
    let lineStart = 0;
    if (startOffset > 0) {
      const firstNewline = buffer.indexOf(0x0a);
      lineStart = firstNewline < 0 ? buffer.length : firstNewline + 1;
    }
    for (let cursor = lineStart; cursor <= buffer.length; cursor += 1) {
      if (cursor < buffer.length && buffer[cursor] !== 0x0a) continue;
      const line = buffer.subarray(lineStart, cursor).toString("utf8");
      if (line.trim()) {
        try {
          const value = JSON.parse(line) as Record<string, unknown>;
          const message = value.message && typeof value.message === "object" ? value.message as Record<string, unknown> : undefined;
          const role = message?.role;
          const visibleMessage = role === "user" || (role === "assistant" && message?.stopReason !== "toolUse");
          if (typeof value.id === "string" && value.type === "message" && visibleMessage) {
            indexed.push({ entry: value as SessionEntry, offset: startOffset + lineStart });
          }
        } catch {}
      }
      lineStart = cursor + 1;
    }
    const entryLimit = Math.min(120, Math.max(20, options.limit ?? 60));
    const selected = indexed.slice(-entryLimit);
    if (selected.length < Math.min(20, entryLimit) && startOffset > 0 && byteBudget < 64 * 1024 * 1024) {
      return readSessionEntryPage(sessionFile, {
        ...options,
        byteBudget: Math.min(64 * 1024 * 1024, byteBudget * 2),
      });
    }
    const cursorOffset = selected[0]?.offset ?? startOffset;
    return {
      entries: selected.map((value) => value.entry),
      cursorOffset,
      hasMore: cursorOffset > 0,
    };
  } finally {
    closeSync(descriptor);
  }
}

export function readRecentSessionEntries(
  sessionFile: string,
  byteBudget = 8 * 1024 * 1024,
): { entries: SessionEntry[]; truncated: boolean } {
  const page = readSessionEntryPage(sessionFile, { byteBudget });
  return { entries: page.entries, truncated: page.hasMore };
}

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
