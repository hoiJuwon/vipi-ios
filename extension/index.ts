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
  activeMessageID?: string;
};

export default function vipiBridge(pi: ExtensionAPI) {
  const runtime: RuntimeState = { phase: "idle", unread: false };

  function sessionSnapshot(ctx: ExtensionContext) {
    const sessionID = ctx.sessionManager.getSessionId();
    const name = pi.getSessionName() ?? "기타 / 이름 없는 세션";
    return {
      id: sessionID, name, cwd: ctx.cwd, phase: runtime.phase, unread: runtime.unread,
      lastActivityAt: new Date().toISOString(),
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

  function send(type: string, payload: unknown) {
    if (runtime.socket?.readyState === WebSocket.OPEN) {
      runtime.socket.send(JSON.stringify({ type, protocolVersion: PROTOCOL_VERSION, payload }));
    }
  }

  function connect(ctx: ExtensionContext) {
    runtime.ctx = ctx;
    if (runtime.socket && runtime.socket.readyState <= WebSocket.OPEN) return;
    let token: string;
    try { token = readFileSync(tokenPath, "utf8").trim(); } catch { return; }
    const socket = new WebSocket(brokerURL, { maxPayload: 512 * 1024 });
    runtime.socket = socket;
    socket.on("open", () => send("runtime.register", { token, session: sessionSnapshot(ctx) }));
    socket.on("message", (raw) => void handleCommand(JSON.parse(raw.toString()) as { id?: string; type: string; payload?: Record<string, unknown> }));
    socket.on("close", () => {
      runtime.socket = undefined;
      runtime.reconnect = setTimeout(() => runtime.ctx && connect(runtime.ctx), 2000);
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
      if (message.type === "session.history") {
        const afterEntryID = typeof message.payload?.afterEntryID === "string" ? message.payload.afterEntryID : undefined;
        reply(true, normalizeHistory(ctx.sessionManager.getBranch(), afterEntryID)); return;
      }
      reply(false, { error: "unsupported command" });
    } catch (error) { reply(false, { error: error instanceof Error ? error.message : String(error) }); }
  }

  pi.on("session_start", async (_event, ctx) => { runtime.phase = "idle"; connect(ctx); send("runtime.session", { session: sessionSnapshot(ctx) }); });
  pi.on("session_info_changed", async (_event, ctx) => send("runtime.session", { session: sessionSnapshot(ctx) }));
  pi.on("agent_start", async (_event, ctx) => { runtime.phase = "working"; runtime.unread = false; send("runtime.session", { session: sessionSnapshot(ctx) }); });
  pi.on("message_start", async (event, ctx) => {
    runtime.activeMessageID = crypto.randomUUID();
    const normalized = normalizeMessage(event.message, runtime.activeMessageID, true);
    if (normalized) send("runtime.event", { sessionID: ctx.sessionManager.getSessionId(), event: normalized });
  });
  pi.on("message_update", async (event, ctx) => {
    runtime.activeMessageID ??= crypto.randomUUID();
    const normalized = normalizeMessage(event.message, runtime.activeMessageID, true);
    if (normalized) send("runtime.event", { sessionID: ctx.sessionManager.getSessionId(), event: normalized });
  });
  pi.on("tool_execution_start", async (event, ctx) => {
    const normalized = normalizeToolEvent(event);
    if (normalized) send("runtime.event", { sessionID: ctx.sessionManager.getSessionId(), event: normalized });
  });
  pi.on("tool_execution_update", async (event, ctx) => {
    const normalized = normalizeToolEvent(event);
    if (normalized) send("runtime.event", { sessionID: ctx.sessionManager.getSessionId(), event: normalized });
  });
  pi.on("tool_execution_end", async (event, ctx) => {
    const normalized = normalizeToolEvent(event);
    if (normalized) send("runtime.event", { sessionID: ctx.sessionManager.getSessionId(), event: normalized });
  });
  pi.on("message_end", async (event, ctx) => {
    runtime.activeMessageID ??= crypto.randomUUID();
    const normalized = normalizeMessage(event.message, runtime.activeMessageID, false);
    if (normalized) send("runtime.event", { sessionID: ctx.sessionManager.getSessionId(), event: normalized });
    runtime.activeMessageID = undefined;
  });
  pi.on("agent_settled", async (_event, ctx) => { runtime.phase = "completed"; runtime.unread = true; send("runtime.session", { session: sessionSnapshot(ctx) }); });
  pi.on("session_shutdown", async () => { if (runtime.reconnect) clearTimeout(runtime.reconnect); runtime.socket?.close(); });
}
