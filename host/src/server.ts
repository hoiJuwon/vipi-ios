import { createServer } from "node:http";
import { WebSocketServer, WebSocket } from "ws";
import qrcode from "qrcode-terminal";
import { envelope, PROTOCOL_VERSION, type Envelope, type SessionRecord } from "./protocol.js";
import { loadOrCreateToken, rotateToken, tokenMatches, tokenPath } from "./token.js";
import { readTmuxRegistry, setTmuxSessionUnread } from "./registry.js";
import { createPairingPayload } from "./pairing.js";
import { mobileActivityForTool, normalizeHistory } from "./normalization.js";
import { readSessionBranch } from "./session-history.js";

const host = process.env.VIPI_HOST ?? "127.0.0.1";
const port = Number(process.env.VIPI_PORT ?? "8765");
const loopbackHosts = new Set(["127.0.0.1", "::1", "localhost"]);
if (!loopbackHosts.has(host) && process.env.VIPI_ALLOW_NON_LOOPBACK !== "1") {
  throw new Error("Refusing non-loopback bind; publish 127.0.0.1 through Tailscale Serve instead");
}
let token = loadOrCreateToken();
const pairingPayload = process.env.VIPI_SHOW_PAIRING_QR === "1"
  ? createPairingPayload(process.env.VIPI_PUBLIC_URL, token)
  : undefined;
let sequence = 0;
const replayLimit = Math.max(100, Number(process.env.VIPI_REPLAY_LIMIT ?? "1000"));
const unauthenticatedRateLimit = Math.max(10, Number(process.env.VIPI_UNAUTHENTICATED_RATE_LIMIT ?? "30"));
const mobileRateLimit = Math.max(30, Number(process.env.VIPI_MOBILE_RATE_LIMIT ?? "120"));
const runtimeRateLimit = Math.max(1_000, Number(process.env.VIPI_RUNTIME_RATE_LIMIT ?? "12000"));
const replayBuffer: Envelope[] = [];
const mobileClients = new Set<WebSocket>();
const runtimes = new Map<string, WebSocket>();
const runtimePanes = new Map<string, string>();
const liveSessions = new Map<string, SessionRecord>();
const pendingRequests = new Map<string, WebSocket>();
const pendingAssistantEvents = new Map<string, Record<string, unknown>>();
const pendingInteractions = new Map<string, string>();

const server = createServer((request, response) => {
  if (request.url === "/health") {
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({
      ok: true,
      protocolVersion: PROTOCOL_VERSION,
      sessions: mergedSessions().length,
      mobileClients: mobileClients.size,
      runtimes: runtimes.size,
    }));
    return;
  }
  response.writeHead(404).end();
});

const wss = new WebSocketServer({ server, path: "/ws", maxPayload: 512 * 1024 });
wss.on("connection", (socket) => {
  let role: "unknown" | "mobile" | "runtime" = "unknown";
  let runtimeSessionID: string | undefined;
  let rateWindowStarted = Date.now();
  let rateCount = 0;
  const authTimer = setTimeout(() => socket.close(4001, "authentication timeout"), 10_000);
  // ws emits an error before closing oversized or malformed peers. Keep that
  // peer-local so one stale runtime can never terminate the personal host.
  socket.on("error", () => {});

  socket.on("message", (raw) => {
    const now = Date.now();
    if (now - rateWindowStarted >= 60_000) { rateWindowStarted = now; rateCount = 0; }
    const rateLimit = role === "runtime" ? runtimeRateLimit : role === "mobile" ? mobileRateLimit : unauthenticatedRateLimit;
    if (++rateCount > rateLimit) { socket.close(4008, "rate limit exceeded"); return; }
    let message: Envelope<Record<string, unknown>>;
    try { message = JSON.parse(raw.toString()) as Envelope<Record<string, unknown>>; }
    catch { socket.send(JSON.stringify(envelope("error", { code: "BAD_JSON" }))); return; }
    if (message.protocolVersion !== PROTOCOL_VERSION) { socket.close(4002, "protocol mismatch"); return; }

    if (role === "unknown") {
      if (message.type === "auth.authenticate" && tokenMatches(token, message.payload?.token)) {
        role = "mobile"; mobileClients.add(socket); clearTimeout(authTimer);
        notifyRuntimeMobilePresence();
        const lastSeq = typeof message.payload?.lastSeq === "number" ? message.payload.lastSeq : undefined;
        const brokerHead = sequence;
        socket.send(JSON.stringify(envelope("auth.ok", { role }, message.id, ++sequence)));
        const oldestSeq = replayBuffer[0]?.seq ?? brokerHead;
        if (lastSeq !== undefined && lastSeq >= oldestSeq - 1 && lastSeq <= brokerHead) {
          for (const item of replayBuffer) if ((item.seq ?? 0) > lastSeq) socket.send(JSON.stringify(item));
        } else {
          socket.send(JSON.stringify(envelope("sessions.snapshot", { sessions: mergedSessions(), replayReset: lastSeq !== undefined }, undefined, ++sequence)));
        }
        return;
      }
      if (message.type === "runtime.register" && tokenMatches(token, message.payload?.token)) {
        const session = message.payload.session as unknown as SessionRecord;
        if (!session?.id) { socket.close(4003, "invalid session"); return; }
        const registered = readTmuxRegistry().find((candidate) => candidate.id === session.id);
        const paneID = session.tmux?.paneID;
        if (registered && paneID && registered.tmux.paneID !== paneID) {
          socket.close(4009, "stale tmux runtime"); return;
        }
        const previous = runtimes.get(session.id);
        if (previous && previous !== socket) previous.close(4009, "runtime replaced");
        role = "runtime"; runtimeSessionID = session.id; runtimes.set(session.id, socket);
        if (paneID) runtimePanes.set(session.id, paneID);
        liveSessions.set(session.id, session);
        clearTimeout(authTimer); broadcast("sessions.snapshot", { sessions: mergedSessions() });
        socket.send(JSON.stringify(envelope("runtime.mobilePresence", { connected: mobileClients.size > 0 }, undefined, ++sequence)));
        return;
      }
      socket.close(4001, "unauthorized"); return;
    }

    if (role === "runtime") {
      if (message.type === "runtime.interaction") {
        const requestID = typeof message.payload.requestID === "string" ? message.payload.requestID : undefined;
        const kind = typeof message.payload.kind === "string" && ["confirm", "select", "input"].includes(message.payload.kind)
          ? message.payload.kind : undefined;
        if (!requestID || !runtimeSessionID || !kind) return;
        if (mobileClients.size === 0) {
          socket.send(JSON.stringify(envelope("runtime.mobilePresence", { connected: false }, undefined, ++sequence)));
          return;
        }
        const interaction = {
          requestID,
          sessionID: runtimeSessionID,
          kind,
          title: String(message.payload.title ?? "Action required").slice(0, 300),
          ...(typeof message.payload.message === "string" ? { message: message.payload.message.slice(0, 8_000) } : {}),
          ...(Array.isArray(message.payload.options) ? {
            options: message.payload.options.filter((value): value is string => typeof value === "string").slice(0, 30).map((value) => value.slice(0, 500)),
          } : {}),
          ...(typeof message.payload.placeholder === "string" ? { placeholder: message.payload.placeholder.slice(0, 500) } : {}),
        };
        pendingInteractions.set(requestID, runtimeSessionID);
        broadcastEphemeral("session.interaction", interaction);
      } else if (message.type === "runtime.session") {
        const session = message.payload.session as unknown as SessionRecord;
        const previousPhase = session?.id ? liveSessions.get(session.id)?.phase : undefined;
        if (session?.id) {
          liveSessions.set(session.id, session);
          if (session.phase === "working" && previousPhase !== "working") pendingAssistantEvents.delete(session.id);
        }
        broadcast("sessions.snapshot", { sessions: mergedSessions() });
        if (session?.id && session.phase !== "working") {
          const pending = pendingAssistantEvents.get(session.id);
          if (pending) {
            pendingAssistantEvents.delete(session.id);
            broadcast("session.event", pending);
          }
        }
      } else if (message.type === "runtime.response") {
        const requestID = typeof message.payload.requestID === "string" ? message.payload.requestID : undefined;
        const requester = requestID ? pendingRequests.get(requestID) : undefined;
        if (requester?.readyState === WebSocket.OPEN) {
          requester.send(JSON.stringify(envelope("session.response", message.payload, requestID, ++sequence)));
        }
        if (requestID) pendingRequests.delete(requestID);
      } else if (message.type === "runtime.event") {
        relayRuntimeEvent(message.payload);
      } else if (message.type.startsWith("runtime.")) {
        broadcast(message.type.replace("runtime.", "session."), message.payload);
      }
      return;
    }

    if (message.type === "sessions.list") {
      socket.send(JSON.stringify(envelope("sessions.snapshot", { sessions: mergedSessions() }, message.id, ++sequence)));
      return;
    }
    if (message.type === "auth.rotate") {
      token = rotateToken();
      socket.send(JSON.stringify(envelope("auth.rotated", { token }, message.id, ++sequence)));
      for (const client of mobileClients) if (client !== socket) client.close(4001, "token rotated");
      return;
    }
    if (message.type === "session.interaction.respond") {
      const requestID = typeof message.payload?.requestID === "string" ? message.payload.requestID : undefined;
      const sessionID = typeof message.payload?.sessionID === "string" ? message.payload.sessionID : undefined;
      const registeredSessionID = requestID ? pendingInteractions.get(requestID) : undefined;
      const runtime = sessionID && registeredSessionID === sessionID ? currentRuntime(sessionID) : undefined;
      if (!requestID || !runtime || runtime.readyState !== WebSocket.OPEN) {
        socket.send(JSON.stringify(envelope("error", { code: "INTERACTION_EXPIRED" }, message.id, ++sequence)));
        return;
      }
      pendingInteractions.delete(requestID);
      runtime.send(JSON.stringify(message));
      socket.send(JSON.stringify(envelope("session.response", { requestID: message.id, ok: true }, message.id, ++sequence)));
      return;
    }
    if (message.type === "session.read") {
      const sessionID = message.payload?.sessionID;
      const ok = typeof sessionID === "string" && setTmuxSessionUnread(sessionID, false);
      socket.send(JSON.stringify(envelope("session.response", {
        requestID: message.id,
        ok,
        ...(!ok ? { result: { error: "session is not visible in the session tree" } } : {}),
      }, message.id, ++sequence)));
      if (ok && typeof sessionID === "string") {
        const runtime = currentRuntime(sessionID);
        if (runtime?.readyState === WebSocket.OPEN) runtime.send(JSON.stringify(message));
        broadcast("sessions.snapshot", { sessions: mergedSessions() });
      }
      return;
    }
    if (!new Set(["session.prompt", "session.abort", "session.compact", "session.history"]).has(message.type)) {
      socket.send(JSON.stringify(envelope("error", { code: "UNSUPPORTED_COMMAND" }, message.id, ++sequence)));
      return;
    }
    const sessionID = message.payload?.sessionID;
    if (typeof sessionID !== "string") return;
    if (message.type === "session.history") {
      const session = mergedSessions().find((candidate) => candidate.id === sessionID);
      if (session?.sessionFile) {
        try {
          const result = normalizeHistory(readSessionBranch(session.sessionFile), {
            afterEntryID: typeof message.payload?.afterEntryID === "string" ? message.payload.afterEntryID : undefined,
            beforeEntryID: typeof message.payload?.beforeEntryID === "string" ? message.payload.beforeEntryID : undefined,
            limit: typeof message.payload?.limit === "number" ? message.payload.limit : undefined,
          });
          socket.send(JSON.stringify(envelope("session.response", { requestID: message.id, ok: true, result }, message.id, ++sequence)));
          return;
        } catch {
          // Fall through to the live runtime when the file is temporarily
          // unavailable. The host remains read-only either way.
        }
      }
    }
    const runtime = currentRuntime(sessionID);
    if (!runtime || runtime.readyState !== WebSocket.OPEN) {
      socket.send(JSON.stringify(envelope("error", { code: "SESSION_OFFLINE", sessionID }, message.id, ++sequence)));
      return;
    }
    if (message.id) pendingRequests.set(message.id, socket);
    runtime.send(JSON.stringify(message));
  });

  socket.on("close", () => {
    clearTimeout(authTimer);
    const wasMobile = mobileClients.delete(socket);
    if (wasMobile) notifyRuntimeMobilePresence();
    for (const [requestID, requester] of pendingRequests) if (requester === socket) pendingRequests.delete(requestID);
    if (runtimeSessionID && runtimes.get(runtimeSessionID) === socket) {
      runtimes.delete(runtimeSessionID);
      runtimePanes.delete(runtimeSessionID);
      pendingAssistantEvents.delete(runtimeSessionID);
      for (const [requestID, sessionID] of pendingInteractions) {
        if (sessionID === runtimeSessionID) pendingInteractions.delete(requestID);
      }
      const session = liveSessions.get(runtimeSessionID);
      if (session) liveSessions.set(runtimeSessionID, { ...session, phase: "offline" });
      broadcast("sessions.snapshot", { sessions: mergedSessions() });
    }
  });
});

function currentRuntime(sessionID: string): WebSocket | undefined {
  const runtime = runtimes.get(sessionID);
  if (!runtime || runtime.readyState !== WebSocket.OPEN) return undefined;
  const registered = readTmuxRegistry().find((candidate) => candidate.id === sessionID);
  const runtimePane = runtimePanes.get(sessionID);
  if (registered && runtimePane && registered.tmux.paneID !== runtimePane) {
    runtimes.delete(sessionID);
    runtimePanes.delete(sessionID);
    runtime.close(4009, "stale tmux runtime");
    return undefined;
  }
  return runtime;
}

function mergedSessions(): SessionRecord[] {
  const treeSessions = readTmuxRegistry();
  lastTreeFingerprint = JSON.stringify(treeSessions);
  const visibleIDs = new Set(treeSessions.map((session) => session.id));
  for (const id of liveSessions.keys()) if (!visibleIDs.has(id)) liveSessions.delete(id);

  return treeSessions.map((treeSession): SessionRecord => {
    const live = currentRuntime(treeSession.id) ? liveSessions.get(treeSession.id) : undefined;
    if (!live) return { ...treeSession, phase: "offline" };
    return {
      ...treeSession,
      phase: live.phase,
      lastActivityAt: live.lastActivityAt,
      lastMessagePreview: live.lastMessagePreview ?? treeSession.lastMessagePreview,
      model: live.model,
      thinkingLevel: live.thinkingLevel,
      branch: live.branch,
      contextPercent: live.contextPercent,
    };
  }).sort((a, b) => b.lastActivityAt.localeCompare(a.lastActivityAt));
}

function treeFingerprint(): string {
  return JSON.stringify(readTmuxRegistry());
}

let lastTreeFingerprint = treeFingerprint();
setInterval(() => {
  const next = treeFingerprint();
  if (next === lastTreeFingerprint) return;
  lastTreeFingerprint = next;
  broadcast("sessions.snapshot", { sessions: mergedSessions() });
}, 250).unref();

function relayRuntimeEvent(payload: Record<string, unknown>): void {
  const sessionID = typeof payload.sessionID === "string" ? payload.sessionID : undefined;
  const event = payload.event && typeof payload.event === "object" ? payload.event as Record<string, unknown> : undefined;
  if (!sessionID || !event) return;

  if (event.kind === "tool") {
    const name = typeof event.name === "string" ? event.name : "tool";
    const activity = event.state === "running" ? mobileActivityForTool(name) : "thinking";
    broadcast("session.event", {
      sessionID,
      event: { kind: "progress", activity, timestamp: new Date().toISOString() },
    });
    return;
  }
  if (event.kind === "progress") {
    const allowed = new Set(["thinking", "reading", "editing", "running", "searching"]);
    const activity = typeof event.activity === "string" && allowed.has(event.activity) ? event.activity : "thinking";
    broadcast("session.event", {
      sessionID,
      event: { kind: "progress", activity, timestamp: typeof event.timestamp === "string" ? event.timestamp : new Date().toISOString() },
    });
    return;
  }
  if (event.kind !== "message" || (event.role !== "user" && event.role !== "assistant")) return;
  if (event.role === "assistant" && event.streaming === true) return;
  const text = typeof event.text === "string" ? event.text : "";
  if (!text.trim()) return;
  const sanitized = {
    sessionID,
    event: {
      kind: "message",
      messageID: typeof event.messageID === "string" ? event.messageID : crypto.randomUUID(),
      role: event.role,
      text,
      timestamp: typeof event.timestamp === "string" ? event.timestamp : new Date().toISOString(),
      streaming: false,
    },
  };
  if (event.role === "assistant" && liveSessions.get(sessionID)?.phase === "working") {
    pendingAssistantEvents.set(sessionID, sanitized);
  } else {
    broadcast("session.event", sanitized);
  }
}

function broadcastEphemeral(type: string, payload: unknown): void {
  const data = JSON.stringify(envelope(type, payload, undefined, ++sequence));
  for (const client of mobileClients) if (client.readyState === WebSocket.OPEN) client.send(data);
}

function notifyRuntimeMobilePresence(): void {
  const connected = mobileClients.size > 0;
  if (!connected) pendingInteractions.clear();
  const data = JSON.stringify(envelope("runtime.mobilePresence", { connected }, undefined, ++sequence));
  for (const runtime of runtimes.values()) if (runtime.readyState === WebSocket.OPEN) runtime.send(data);
}

function broadcast(type: string, payload: unknown): void {
  const item = envelope(type, payload, undefined, ++sequence);
  replayBuffer.push(item);
  if (replayBuffer.length > replayLimit) replayBuffer.splice(0, replayBuffer.length - replayLimit);
  const data = JSON.stringify(item);
  for (const client of mobileClients) if (client.readyState === WebSocket.OPEN) client.send(data);
}

server.listen(port, host, () => {
  const local = `http://${host}:${port}`;
  console.log(`Vipi host listening on ${local}`);
  console.log(`Authentication token stored at ${tokenPath}`);
  console.log(`Tailscale: tailscale serve --bg ${local}`);
  if (pairingPayload) {
    console.warn(`Pairing for ${pairingPayload.host}. The QR contains a bearer secret; scan it privately and clear this terminal afterward.`);
    qrcode.generate(JSON.stringify(pairingPayload), { small: true });
  }
});
