import { createServer } from "node:http";
import { WebSocketServer, WebSocket } from "ws";
import qrcode from "qrcode-terminal";
import { envelope, PROTOCOL_VERSION, type Envelope, type SessionRecord } from "./protocol.js";
import { loadOrCreateToken, rotateToken, tokenMatches, tokenPath } from "./token.js";
import { readTmuxRegistry } from "./registry.js";

const host = process.env.VIPI_HOST ?? "127.0.0.1";
const port = Number(process.env.VIPI_PORT ?? "8765");
const loopbackHosts = new Set(["127.0.0.1", "::1", "localhost"]);
if (!loopbackHosts.has(host) && process.env.VIPI_ALLOW_NON_LOOPBACK !== "1") {
  throw new Error("Refusing non-loopback bind; publish 127.0.0.1 through Tailscale Serve instead");
}
let token = loadOrCreateToken();
let sequence = 0;
const replayLimit = Math.max(100, Number(process.env.VIPI_REPLAY_LIMIT ?? "1000"));
const replayBuffer: Envelope[] = [];
const mobileClients = new Set<WebSocket>();
const runtimes = new Map<string, WebSocket>();
const liveSessions = new Map<string, SessionRecord>();
const pendingRequests = new Map<string, WebSocket>();

const server = createServer((request, response) => {
  if (request.url === "/health") {
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({ ok: true, protocolVersion: PROTOCOL_VERSION, sessions: mergedSessions().length }));
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

  socket.on("message", (raw) => {
    const now = Date.now();
    if (now - rateWindowStarted >= 60_000) { rateWindowStarted = now; rateCount = 0; }
    if (++rateCount > 120) { socket.close(4008, "rate limit exceeded"); return; }
    let message: Envelope<Record<string, unknown>>;
    try { message = JSON.parse(raw.toString()) as Envelope<Record<string, unknown>>; }
    catch { socket.send(JSON.stringify(envelope("error", { code: "BAD_JSON" }))); return; }
    if (message.protocolVersion !== PROTOCOL_VERSION) { socket.close(4002, "protocol mismatch"); return; }

    if (role === "unknown") {
      if (message.type === "auth.authenticate" && tokenMatches(token, message.payload?.token)) {
        role = "mobile"; mobileClients.add(socket); clearTimeout(authTimer);
        const lastSeq = typeof message.payload?.lastSeq === "number" ? message.payload.lastSeq : undefined;
        socket.send(JSON.stringify(envelope("auth.ok", { role }, message.id, ++sequence)));
        const oldestSeq = replayBuffer[0]?.seq ?? sequence;
        if (lastSeq !== undefined && lastSeq >= oldestSeq - 1) {
          for (const item of replayBuffer) if ((item.seq ?? 0) > lastSeq) socket.send(JSON.stringify(item));
        } else {
          socket.send(JSON.stringify(envelope("sessions.snapshot", { sessions: mergedSessions(), replayReset: lastSeq !== undefined }, undefined, ++sequence)));
        }
        return;
      }
      if (message.type === "runtime.register" && tokenMatches(token, message.payload?.token)) {
        const session = message.payload.session as unknown as SessionRecord;
        if (!session?.id) { socket.close(4003, "invalid session"); return; }
        role = "runtime"; runtimeSessionID = session.id; runtimes.set(session.id, socket); liveSessions.set(session.id, session);
        clearTimeout(authTimer); broadcast("sessions.snapshot", { sessions: mergedSessions() });
        return;
      }
      socket.close(4001, "unauthorized"); return;
    }

    if (role === "runtime") {
      if (message.type === "runtime.session") {
        const session = message.payload.session as unknown as SessionRecord;
        if (session?.id) liveSessions.set(session.id, session);
        broadcast("sessions.snapshot", { sessions: mergedSessions() });
      } else if (message.type === "runtime.response") {
        const requestID = typeof message.payload.requestID === "string" ? message.payload.requestID : undefined;
        const requester = requestID ? pendingRequests.get(requestID) : undefined;
        if (requester?.readyState === WebSocket.OPEN) {
          requester.send(JSON.stringify(envelope("session.response", message.payload, requestID, ++sequence)));
        }
        if (requestID) pendingRequests.delete(requestID);
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
    if (!new Set(["session.prompt", "session.abort", "session.compact", "session.history"]).has(message.type)) {
      socket.send(JSON.stringify(envelope("error", { code: "UNSUPPORTED_COMMAND" }, message.id, ++sequence)));
      return;
    }
    const sessionID = message.payload?.sessionID;
    if (typeof sessionID !== "string") return;
    const runtime = runtimes.get(sessionID);
    if (!runtime || runtime.readyState !== WebSocket.OPEN) {
      socket.send(JSON.stringify(envelope("error", { code: "SESSION_OFFLINE", sessionID }, message.id, ++sequence)));
      return;
    }
    if (message.id) pendingRequests.set(message.id, socket);
    runtime.send(JSON.stringify(message));
  });

  socket.on("close", () => {
    clearTimeout(authTimer); mobileClients.delete(socket);
    for (const [requestID, requester] of pendingRequests) if (requester === socket) pendingRequests.delete(requestID);
    if (runtimeSessionID && runtimes.get(runtimeSessionID) === socket) {
      runtimes.delete(runtimeSessionID);
      const session = liveSessions.get(runtimeSessionID);
      if (session) liveSessions.set(runtimeSessionID, { ...session, phase: "offline" });
      broadcast("sessions.snapshot", { sessions: mergedSessions() });
    }
  });
});

function mergedSessions(): SessionRecord[] {
  const sessions = new Map(readTmuxRegistry().map((session) => [session.id, session]));
  for (const [id, session] of liveSessions) sessions.set(id, session);
  return [...sessions.values()].sort((a, b) => b.lastActivityAt.localeCompare(a.lastActivityAt));
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
  if (process.env.VIPI_SHOW_PAIRING_QR === "1") {
    console.warn("Pairing QR contains a bearer secret; scan it privately and clear this terminal afterward.");
    qrcode.generate(JSON.stringify({ host: local, token }), { small: true });
  }
});
