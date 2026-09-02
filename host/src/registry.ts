import { closeSync, existsSync, openSync, readFileSync, readSync, renameSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { normalizeHistory } from "./normalization.js";
import type { SessionRecord } from "./protocol.js";
import { agentDir } from "./token.js";

type RawEntry = {
  piSessionId?: string; sessionFile?: string; name?: string; status?: "idle" | "working";
  unread?: boolean; cwd?: string; tmuxSession?: string; tmuxWindow?: string;
  tmuxPaneId?: string; lastSeen?: string;
};

type PreviewSnapshot = { fingerprint: string; preview?: string; timestamp?: string };
const previews = new Map<string, PreviewSnapshot>();
const registryPath = join(agentDir, "tmux-session-tree.json");

export function tmuxRegistryRevision(): string {
  try {
    const metadata = statSync(registryPath);
    return `${metadata.ino}:${metadata.size}:${metadata.mtimeMs}`;
  } catch {
    return "missing";
  }
}

function recentTailEntries(sessionFile: string, size: number): Array<Record<string, unknown>> {
  const budget = Math.min(size, 512 * 1024);
  if (budget <= 0) return [];
  const descriptor = openSync(sessionFile, "r");
  try {
    const buffer = Buffer.allocUnsafe(budget);
    readSync(descriptor, buffer, 0, budget, size - budget);
    const text = buffer.toString("utf8");
    const lines = text.split("\n");
    if (size > budget) lines.shift();
    return lines.flatMap((line): Array<Record<string, unknown>> => {
      if (!line.trim()) return [];
      try {
        const value = JSON.parse(line) as Record<string, unknown>;
        return typeof value.id === "string" ? [value] : [];
      } catch { return []; }
    });
  } finally {
    closeSync(descriptor);
  }
}

function recentMessageSnapshot(sessionFile: string | undefined): Omit<PreviewSnapshot, "fingerprint"> {
  if (!sessionFile) return {};
  try {
    const metadata = statSync(sessionFile);
    const fingerprint = `${metadata.size}:${metadata.mtimeMs}`;
    const cached = previews.get(sessionFile);
    if (cached?.fingerprint === fingerprint) return cached;
    // Session-list rendering must never parse an entire rollout. The live
    // runtime supplies the freshest preview; cold start reads only a bounded
    // tail for an offline fallback.
    const event = normalizeHistory(recentTailEntries(sessionFile, metadata.size)).events.findLast((candidate) => candidate.kind === "message");
    const snapshot: PreviewSnapshot = {
      fingerprint,
      ...(event?.kind === "message" ? {
        preview: event.text.replace(/\s+/g, " ").trim().slice(0, 180),
        timestamp: event.timestamp,
      } : {}),
    };
    previews.set(sessionFile, snapshot);
    return snapshot;
  } catch {
    previews.delete(sessionFile);
    return {};
  }
}

/** The session tree registry is the canonical mobile visibility boundary. */
export function readTmuxRegistry(): SessionRecord[] {
  try {
    const body = JSON.parse(readFileSync(registryPath, "utf8")) as { entries?: RawEntry[] };
    return (body.entries ?? []).flatMap((entry): SessionRecord[] => {
      // Scheduler/headless runs use synthetic `session:<id>` coordinates.
      // Mobile exposes only user-owned tmux panes and fetches their latest
      // state when the app connects; headless runs must never stream or push.
      if (!entry.piSessionId || !entry.cwd || !entry.sessionFile || !entry.tmuxPaneId?.startsWith("%") || !existsSync(entry.sessionFile)) return [];
      const recent = recentMessageSnapshot(entry.sessionFile);
      return [{
        id: entry.piSessionId,
        name: entry.name || "기타 / 이름 없는 세션",
        cwd: entry.cwd,
        phase: entry.status === "working" ? "working" : "idle",
        unread: entry.unread ?? false,
        lastActivityAt: recent.timestamp ?? entry.lastSeen ?? new Date(0).toISOString(),
        lastMessagePreview: recent.preview,
        model: "Pi",
        thinkingLevel: "—",
        contextPercent: 0,
        tmux: {
          session: entry.tmuxSession ?? "",
          window: entry.tmuxWindow ?? "",
          paneID: entry.tmuxPaneId ?? `session:${entry.piSessionId}`,
        },
        sessionFile: entry.sessionFile,
      }];
    });
  } catch { return []; }
}

/** Persists the same unread bit consumed and rendered by pi-session-tree. */
export function setTmuxSessionUnread(sessionID: string, unread: boolean): boolean {
  try {
    const body = JSON.parse(readFileSync(registryPath, "utf8")) as { entries?: RawEntry[] };
    if (!Array.isArray(body.entries)) return false;
    let found = false;
    let changed = false;
    const entries = body.entries.map((entry) => {
      if (entry.piSessionId !== sessionID) return entry;
      found = true;
      if (entry.unread === unread) return entry;
      changed = true;
      return { ...entry, unread };
    });
    if (!found) return false;
    if (!changed) return true;

    const temporary = `${registryPath}.vipi-${process.pid}-${Date.now()}`;
    try {
      writeFileSync(temporary, JSON.stringify({ ...body, entries }, null, 2), { mode: 0o600 });
      renameSync(temporary, registryPath);
    } finally {
      try { unlinkSync(temporary); } catch {}
    }
    return true;
  } catch {
    return false;
  }
}
