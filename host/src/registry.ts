import { existsSync, readFileSync, renameSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { normalizeHistory } from "./normalization.js";
import type { SessionRecord } from "./protocol.js";
import { readSessionBranch } from "./session-history.js";
import { agentDir } from "./token.js";

type RawEntry = {
  piSessionId?: string; sessionFile?: string; name?: string; status?: "idle" | "working";
  unread?: boolean; cwd?: string; tmuxSession?: string; tmuxWindow?: string;
  tmuxPaneId?: string; lastSeen?: string;
};

type PreviewSnapshot = { fingerprint: string; preview?: string; timestamp?: string };
const previews = new Map<string, PreviewSnapshot>();
const registryPath = join(agentDir, "tmux-session-tree.json");

function recentMessageSnapshot(sessionFile: string | undefined): Omit<PreviewSnapshot, "fingerprint"> {
  if (!sessionFile) return {};
  try {
    const metadata = statSync(sessionFile);
    const fingerprint = `${metadata.size}:${metadata.mtimeMs}`;
    const cached = previews.get(sessionFile);
    if (cached?.fingerprint === fingerprint) return cached;
    const event = normalizeHistory(readSessionBranch(sessionFile)).events.findLast((candidate) => candidate.kind === "message");
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
      if (!entry.piSessionId || !entry.cwd || !entry.sessionFile || !existsSync(entry.sessionFile)) return [];
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
