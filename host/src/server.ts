import { createServer } from "node:http";
import { WebSocketServer, WebSocket } from "ws";
import qrcode from "qrcode-terminal";
import { envelope, PROTOCOL_VERSION, type Envelope, type SessionRecord } from "./protocol.js";
import { loadOrCreateToken, tokenMatches } from "./token.js";
import { readTmuxRegistry } from "./registry.js";

const host = process.env.VIPI_HOST ?? "127.0.0.1";
const port = Number(process.env.VIPI_PORT ?? "8765");
const token = loadOrCreateToken();
let sequence = 0;
const mobileClients = new Set<WebSocket>();
const runtimes = new Map<string, WebSocket>();
const liveSessions = new Map<string, SessionRecord>();

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
  const authTimer = setTimeout(() => socket.close(4001, "authentication timeout"), 10_000);

  socket.on("message", (raw) => {
    let message: Envelope<Record<string, unknown>>;
    try { message = JSON.parse(raw.toString()) as Envelope<Record<string, unknown>>; }
    catch { socket.send(JSON.stringify(envelope("error", { code: "BAD_JSON" }))); return; }
    if (message.protocolVersion !== PROTOCOL_VERSION) { socket.close(4002, "protocol mismatch"); return; }

    if (role === "unknown") {
      if (message.type === "auth.authenticate" && tokenMatches(token, message.payload?.token)) {
        role = "mobile"; mobileClients.add(socket); clearTimeout(authTimer);
        socket.send(JSON.stringify(envelope("auth.ok", { role }, message.id, ++sequence)));
        socket.send(JSON.stringify(envelope("sessions.snapshot", { sessions: mergedSessions() }, undefined, ++sequence)));
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
      } else if (message.type.startsWith("runtime.")) {
        broadcast(message.type.replace("runtime.", "session."), message.payload);
      }
      return;
    }

    if (message.type === "sessions.list") {
      socket.send(JSON.stringify(envelope("sessions.snapshot", { sessions: mergedSessions() }, message.id, ++sequence)));
      return;
    }
    const sessionID = message.payload?.sessionID;
    if (typeof sessionID !== "string") return;
    const runtime = runtimes.get(sessionID);
    if (!runtime || runtime.readyState !== WebSocket.OPEN) {
      socket.send(JSON.stringify(envelope("error", { code: "SESSION_OFFLINE", sessionID }, message.id, ++sequence)));
      return;
    }
    runtime.send(JSON.stringify(message));
  });

  socket.on("close", () => {
    clearTimeout(authTimer); mobileClients.delete(socket);
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
  const data = JSON.stringify(envelope(type, payload, undefined, ++sequence));
  for (const client of mobileClients) if (client.readyState === WebSocket.OPEN) client.send(data);
}

server.listen(port, host, () => {
  const local = `http://${host}:${port}`;
  console.log(`Vipi host listening on ${local}`);
  console.log(`Token: ${token}`);
  console.log(`Tailscale: tailscale serve --bg ${local}`);
  qrcode.generate(JSON.stringify({ host: local, token }), { small: true });
});
