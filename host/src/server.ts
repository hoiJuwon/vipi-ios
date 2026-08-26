import { createHash, randomUUID } from "node:crypto";
import { mkdirSync, unlinkSync, writeFileSync } from "node:fs";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { dirname, join } from "node:path";
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
const runtimeCapabilities = new Map<string, { imageAttachments: boolean; goalCommands: boolean }>();
const liveSessions = new Map<string, SessionRecord>();
const pendingRequests = new Map<string, WebSocket>();
const pendingAssistantEvents = new Map<string, Record<string, unknown>>();
const pendingInteractions = new Map<string, string>();
const attachmentDirectory = join(dirname(tokenPath), "attachments");
const attachmentLimit = 6 * 1024 * 1024;
const attachmentTTL = 15 * 60 * 1000;
type PendingAttachment = { id: string; digest: string; mimeType: string; path: string; sessionID: string; expiresAt: number };
const pendingAttachments = new Map<string, PendingAttachment>();
const requestAttachments = new Map<string, string[]>();
mkdirSync(attachmentDirectory, { recursive: true, mode: 0o700 });

const server = createServer((request, response) => {
  if (request.method === "POST" && request.url === "/attachments") {
    receiveAttachment(request, response);
    return;
  }
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

function attachmentMimeType(requested: string | undefined, data: Buffer): string | undefined {
  if (requested === "image/jpeg" && data[0] === 0xff && data[1] === 0xd8 && data[2] === 0xff) return requested;
  if (requested === "image/png" && data.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return requested;
  if (requested === "image/webp" && data.subarray(0, 4).toString("ascii") === "RIFF" && data.subarray(8, 12).toString("ascii") === "WEBP") return requested;
  return undefined;
}

function removeAttachment(id: string): void {
  const attachment = pendingAttachments.get(id);
  if (!attachment) return;
  pendingAttachments.delete(id);
  try { unlinkSync(attachment.path); } catch {}
}

function receiveAttachment(request: IncomingMessage, response: ServerResponse): void {
  const authorization = request.headers.authorization;
  const candidateToken = authorization?.startsWith("Bearer ") ? authorization.slice(7) : undefined;
  if (!tokenMatches(token, candidateToken)) {
    response.writeHead(401, { "content-type": "application/json" }).end(JSON.stringify({ error: "UNAUTHORIZED" }));
    request.resume();
    return;
  }
  const sessionID = typeof request.headers["x-vipi-session-id"] === "string" ? request.headers["x-vipi-session-id"] : undefined;
  if (!sessionID || !currentRuntime(sessionID)) {
    response.writeHead(404, { "content-type": "application/json" }).end(JSON.stringify({ error: "SESSION_OFFLINE" }));
    request.resume();
    return;
  }
  if (runtimeCapabilities.get(sessionID)?.imageAttachments !== true) {
    response.writeHead(409, { "content-type": "application/json" }).end(JSON.stringify({ error: "RUNTIME_UPDATE_REQUIRED" }));
    request.resume();
    return;
  }
  if (pendingAttachments.size >= 24) {
    response.writeHead(429, { "content-type": "application/json" }).end(JSON.stringify({ error: "UPLOAD_CAPACITY" }));
    request.resume();
    return;
  }
  const requestedMimeType = request.headers["content-type"]?.split(";", 1)[0]?.trim().toLowerCase();
  const expectedDigest = typeof request.headers["x-vipi-content-sha256"] === "string"
    ? request.headers["x-vipi-content-sha256"].toLowerCase() : undefined;
  const chunks: Buffer[] = [];
  let size = 0;
  let tooLarge = false;
  request.on("data", (chunk: Buffer) => {
    size += chunk.length;
    if (size > attachmentLimit) { tooLarge = true; chunks.length = 0; return; }
    if (!tooLarge) chunks.push(chunk);
  });
  request.on("end", () => {
    if (tooLarge) {
      response.writeHead(413, { "content-type": "application/json" }).end(JSON.stringify({ error: "IMAGE_TOO_LARGE" }));
      return;
    }
    const data = Buffer.concat(chunks);
    const mimeType = attachmentMimeType(requestedMimeType, data);
    const digest = createHash("sha256").update(data).digest("hex");
    if (!mimeType || !expectedDigest?.match(/^[a-f0-9]{64}$/) || expectedDigest !== digest) {
      response.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ error: "INVALID_IMAGE" }));
      return;
    }
    const id = randomUUID();
    const path = join(attachmentDirectory, `${id}.image`);
    try {
      writeFileSync(path, data, { mode: 0o600 });
      pendingAttachments.set(id, { id, digest, mimeType, path, sessionID, expiresAt: Date.now() + attachmentTTL });
      response.writeHead(201, { "content-type": "application/json", "cache-control": "no-store" });
      response.end(JSON.stringify({ id, digest, mimeType }));
    } catch {
      try { unlinkSync(path); } catch {}
      response.writeHead(500, { "content-type": "application/json" }).end(JSON.stringify({ error: "UPLOAD_FAILED" }));
    }
  });
  request.on("error", () => {
    if (!response.headersSent) response.writeHead(400).end();
  });
}

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
        const capabilities = message.payload.capabilities as Record<string, unknown> | undefined;
        runtimeCapabilities.set(session.id, {
          imageAttachments: capabilities?.imageAttachments === true,
          goalCommands: capabilities?.goalCommands === true,
        });
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
        if (requestID) {
          pendingRequests.delete(requestID);
          for (const attachmentID of requestAttachments.get(requestID) ?? []) removeAttachment(attachmentID);
          requestAttachments.delete(requestID);
        }
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
    let forwardedMessage: Envelope<Record<string, unknown>> = message;
    if (message.type === "session.prompt") {
      const promptText = typeof message.payload?.text === "string" ? message.payload.text : "";
      if (/^\/goal(?:\s|$)/.test(promptText) && runtimeCapabilities.get(sessionID)?.goalCommands !== true) {
        socket.send(JSON.stringify(envelope("error", { code: "RUNTIME_UPDATE_REQUIRED" }, message.id, ++sequence)));
        return;
      }
      const attachmentIDs = Array.isArray(message.payload?.attachments)
        ? message.payload.attachments.flatMap((value): string[] => {
            if (!value || typeof value !== "object") return [];
            const id = (value as Record<string, unknown>).id;
            return typeof id === "string" ? [id] : [];
          }).slice(0, 4)
        : [];
      const attachments = attachmentIDs.map((id) => pendingAttachments.get(id));
      if (attachments.some((attachment) => !attachment || attachment.sessionID !== sessionID || attachment.expiresAt <= Date.now())) {
        socket.send(JSON.stringify(envelope("error", { code: "ATTACHMENT_EXPIRED" }, message.id, ++sequence)));
        return;
      }
      forwardedMessage = {
        ...message,
        payload: {
          ...message.payload,
          attachments: attachments.flatMap((attachment) => attachment ? [{
            id: attachment.id,
            digest: attachment.digest,
            mimeType: attachment.mimeType,
            path: attachment.path,
          }] : []),
        },
      };
      if (message.id && attachmentIDs.length > 0) requestAttachments.set(message.id, attachmentIDs);
    }
    if (message.id) pendingRequests.set(message.id, socket);
    runtime.send(JSON.stringify(forwardedMessage));
  });

  socket.on("close", () => {
    clearTimeout(authTimer);
    const wasMobile = mobileClients.delete(socket);
    if (wasMobile) notifyRuntimeMobilePresence();
    for (const [requestID, requester] of pendingRequests) {
      if (requester !== socket) continue;
      pendingRequests.delete(requestID);
      for (const attachmentID of requestAttachments.get(requestID) ?? []) removeAttachment(attachmentID);
      requestAttachments.delete(requestID);
    }
    if (runtimeSessionID && runtimes.get(runtimeSessionID) === socket) {
      runtimes.delete(runtimeSessionID);
      runtimePanes.delete(runtimeSessionID);
      runtimeCapabilities.delete(runtimeSessionID);
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
    runtimeCapabilities.delete(sessionID);
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

setInterval(() => {
  const now = Date.now();
  for (const [id, attachment] of pendingAttachments) if (attachment.expiresAt <= now) removeAttachment(id);
}, 60_000).unref();

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
  const attachments = event.role === "user" && Array.isArray(event.attachments)
    ? event.attachments.flatMap((value): Array<{ id: string; mimeType: string }> => {
        if (!value || typeof value !== "object") return [];
        const attachment = value as Record<string, unknown>;
        const id = typeof attachment.id === "string" && attachment.id.match(/^[a-f0-9]{64}$/) ? attachment.id : undefined;
        const mimeType = typeof attachment.mimeType === "string" && attachment.mimeType.startsWith("image/") ? attachment.mimeType : undefined;
        return id && mimeType ? [{ id, mimeType }] : [];
      }).slice(0, 4)
    : [];
  if (!text.trim() && attachments.length === 0) return;
  const sanitized = {
    sessionID,
    event: {
      kind: "message",
      messageID: typeof event.messageID === "string" ? event.messageID : crypto.randomUUID(),
      role: event.role,
      text,
      timestamp: typeof event.timestamp === "string" ? event.timestamp : new Date().toISOString(),
      streaming: false,
      ...(attachments.length > 0 ? { attachments } : {}),
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
