import { readFileSync } from "node:fs";
import { join } from "node:path";
import { agentDir } from "./token.js";
import type { SessionRecord } from "./protocol.js";

type RawEntry = {
  piSessionId?: string; sessionFile?: string; name?: string; status?: "idle" | "working";
  unread?: boolean; cwd?: string; tmuxSession?: string; tmuxWindow?: string;
  tmuxPaneId?: string; lastSeen?: string;
};

export function readTmuxRegistry(): SessionRecord[] {
  try {
    const body = JSON.parse(readFileSync(join(agentDir, "tmux-session-tree.json"), "utf8")) as { entries?: RawEntry[] };
    return (body.entries ?? []).flatMap((entry): SessionRecord[] => {
      if (!entry.piSessionId || !entry.cwd || !entry.tmuxSession || !entry.tmuxWindow || !entry.tmuxPaneId) return [];
      return [{
        id: entry.piSessionId,
        name: entry.name || "기타 / 이름 없는 세션",
        cwd: entry.cwd,
        phase: entry.status === "working" ? "working" : "idle",
        unread: entry.unread ?? false,
        lastActivityAt: entry.lastSeen ?? new Date().toISOString(),
        model: "Pi",
        thinkingLevel: "—",
        contextPercent: 0,
        tmux: { session: entry.tmuxSession, window: entry.tmuxWindow, paneID: entry.tmuxPaneId },
        sessionFile: entry.sessionFile,
      }];
    });
  } catch { return []; }
}
