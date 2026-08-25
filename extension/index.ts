import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import WebSocket from "ws";
import { normalizeHistory, normalizeMessage, normalizeToolEvent } from "../host/src/normalization.js";

const PROTOCOL_VERSION = 1;
const agentDir = process.env.PI_CODING_AGENT_DIR ?? join(homedir(), ".pi", "agent");
const tokenPath = join(agentDir, "vipi", "token");
const brokerURL = process.env.VIPI_BROKER_URL ?? "ws://127.0.0.1:8765/ws";

type RuntimeState = {
  ctx?: ExtensionContext;
  socket?: WebSocket;
  reconnect?: NodeJS.Timeout;
  phase: string;
  unread: boolean;
  disposed: boolean;
};

export default function vipiBridge(pi: ExtensionAPI) {
  const runtime: RuntimeState = { phase: "idle", unread: false, disposed: false };

  function recentMessageSnapshot(ctx: ExtensionContext): { preview?: string; timestamp?: string } {
    for (const entry of [...ctx.sessionManager.getBranch()].reverse()) {
      if (entry.type !== "message") continue;
      const normalized = normalizeMessage(entry.message, entry.id, false, entry.id);
      if (!normalized || normalized.kind !== "message" || !normalized.text.trim()) continue;
      return {
        preview: normalized.text.replace(/\s+/g, " ").trim().slice(0, 180),
        timestamp: normalized.timestamp,
      };
    }
    return {};
  }

  function sessionSnapshot(ctx: ExtensionContext) {
    const sessionID = ctx.sessionManager.getSessionId();
    const name = pi.getSessionName() ?? "기타 / 이름 없는 세션";
    const recent = recentMessageSnapshot(ctx);
    return {
      id: sessionID, name, cwd: ctx.cwd, phase: runtime.phase, unread: runtime.unread,
      lastActivityAt: recent.timestamp ?? new Date().toISOString(), lastMessagePreview: recent.preview,
      model: ctx.model?.name ?? ctx.model?.id ?? "Pi",
      thinkingLevel: pi.getThinkingLevel(),
      branch: undefined,
      contextPercent: Math.round(ctx.getContextUsage()?.percent ?? 0),
      tmux: tmuxCoordinates(), sessionFile: ctx.sessionManager.getSessionFile(),
    };
  }

  function tmuxCoordinates() {
    const paneID = process.env.TMUX_PANE ?? "";
    // The existing tmux registry enriches session/window coordinates in the host.
    return { session: process.env.TMUX ? "tmux" : "standalone", window: "?", paneID };
  }

  function persistedMessageID(message: unknown, ctx: ExtensionContext): string | undefined {
    const candidate = message as { role?: unknown; timestamp?: unknown; content?: unknown };
    for (const entry of [...ctx.sessionManager.getBranch()].reverse()) {
      if (entry.type !== "message") continue;
      if (entry.message === message) return entry.id;
      const persisted = entry.message as { role?: unknown; timestamp?: unknown; content?: unknown };
      if (persisted.role === candidate.role && persisted.timestamp === candidate.timestamp &&
          JSON.stringify(persisted.content) === JSON.stringify(candidate.content)) return entry.id;
    }
    return undefined;
  }

  function send(type: string, payload: unknown) {
    if (runtime.socket?.readyState === WebSocket.OPEN) {
      runtime.socket.send(JSON.stringify({ type, protocolVersion: PROTOCOL_VERSION, payload }));
    }
  }

  function connect(ctx: ExtensionContext) {
    if (runtime.disposed) return;
    runtime.ctx = ctx;
    if (runtime.socket && runtime.socket.readyState <= WebSocket.OPEN) return;
    let token: string;
    try { token = readFileSync(tokenPath, "utf8").trim(); } catch { return; }
    const socket = new WebSocket(brokerURL, { maxPayload: 512 * 1024 });
    runtime.socket = socket;
    socket.on("open", () => {
      if (runtime.disposed || runtime.socket !== socket || runtime.ctx !== ctx) {
        socket.close();
        return;
      }
      send("runtime.register", { token, session: sessionSnapshot(ctx) });
    });
    socket.on("message", (raw) => {
      if (runtime.disposed || runtime.socket !== socket) return;
      try {
        void handleCommand(JSON.parse(raw.toString()) as { id?: string; type: string; payload?: Record<string, unknown> });
      } catch {
        socket.close(4002, "invalid broker message");
      }
    });
    socket.on("close", () => {
      if (runtime.socket === socket) runtime.socket = undefined;
      if (runtime.disposed) return;
      runtime.reconnect = setTimeout(() => {
        const activeContext = runtime.ctx;
        if (!runtime.disposed && activeContext) connect(activeContext);
      }, 2000);
      runtime.reconnect.unref?.();
    });
    socket.on("error", () => {});
  }

  async function handleCommand(message: { id?: string; type: string; payload?: Record<string, unknown> }) {
    const ctx = runtime.ctx; if (!ctx) return;
    const reply = (ok: boolean, result?: unknown) => send("runtime.response", { requestID: message.id, ok, result });
    try {
      if (message.type === "session.prompt") {
        const text = String(message.payload?.text ?? "");
        const delivery = message.payload?.delivery as "steer" | "followUp" | "prompt";
        if (!text) throw new Error("empty prompt");
        if (delivery === "steer" || delivery === "followUp") pi.sendUserMessage(text, { deliverAs: delivery });
        else pi.sendUserMessage(text);
        reply(true); return;
      }
      if (message.type === "session.abort") { ctx.abort(); reply(true); return; }
      if (message.type === "session.compact") { ctx.compact(); reply(true); return; }
      if (message.type === "session.history") {
        const afterEntryID = typeof message.payload?.afterEntryID === "string" ? message.payload.afterEntryID : undefined;
        const beforeEntryID = typeof message.payload?.beforeEntryID === "string" ? message.payload.beforeEntryID : undefined;
        const limit = typeof message.payload?.limit === "number" ? message.payload.limit : undefined;
        reply(true, normalizeHistory(ctx.sessionManager.getBranch(), { afterEntryID, beforeEntryID, limit })); return;
      }
      reply(false, { error: "unsupported command" });
    } catch (error) { reply(false, { error: error instanceof Error ? error.message : String(error) }); }
  }

  pi.on("session_start", async (_event, ctx) => { runtime.disposed = false; runtime.phase = "idle"; connect(ctx); send("runtime.session", { session: sessionSnapshot(ctx) }); });
  pi.on("session_info_changed", async (_event, ctx) => send("runtime.session", { session: sessionSnapshot(ctx) }));
  pi.on("agent_start", async (_event, ctx) => {
    runtime.phase = "working";
    runtime.unread = false;
    send("runtime.session", { session: sessionSnapshot(ctx) });
    send("runtime.event", {
      sessionID: ctx.sessionManager.getSessionId(),
      event: { kind: "progress", activity: "thinking", timestamp: new Date().toISOString() },
    });
  });
  // Mobile intentionally receives no assistant deltas. Tool-use commentary can
  // look like a final answer before the run is done, so only message_end sends
  // a tool-free final response.
  pi.on("tool_execution_start", async (event, ctx) => {
    const normalized = normalizeToolEvent(event);
    if (normalized) send("runtime.event", { sessionID: ctx.sessionManager.getSessionId(), event: normalized });
  });
  pi.on("tool_execution_update", async () => {
    // Drop partial tool output at the source. It is large, sensitive, and not
    // part of the mobile chat DTO.
  });
  pi.on("tool_execution_end", async (event, ctx) => {
    const normalized = normalizeToolEvent(event);
    if (normalized) send("runtime.event", { sessionID: ctx.sessionManager.getSessionId(), event: normalized });
  });
  pi.on("message_end", async (event, ctx) => {
    const messageID = persistedMessageID(event.message, ctx) ?? crypto.randomUUID();
    const normalized = normalizeMessage(event.message, messageID, false);
    if (normalized) send("runtime.event", { sessionID: ctx.sessionManager.getSessionId(), event: normalized });
  });
  pi.on("agent_settled", async (_event, ctx) => { runtime.phase = "completed"; runtime.unread = true; send("runtime.session", { session: sessionSnapshot(ctx) }); });
  pi.on("session_shutdown", async () => {
    runtime.disposed = true;
    runtime.ctx = undefined;
    if (runtime.reconnect) clearTimeout(runtime.reconnect);
    runtime.reconnect = undefined;
    const socket = runtime.socket;
    runtime.socket = undefined;
    socket?.removeAllListeners();
    socket?.close();
  });
}
