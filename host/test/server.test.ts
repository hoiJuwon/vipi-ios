import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { writeFileSync } from "node:fs";
import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, test } from "node:test";
import WebSocket from "ws";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { normalizeHistory, normalizeMessage, normalizeToolEvent } from "../src/normalization.js";
import { readSessionBranch } from "../src/session-history.js";
import { createPairingPayload } from "../src/pairing.js";

const protocolVersion = 1;
let child: ChildProcess;
let directory: string;
let port: number;
let token: string;
let hostOutput = "";

async function availablePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      const value = typeof address === "object" && address ? address.port : 0;
      server.close((error) => error ? reject(error) : resolve(value));
    });
  });
}

const inboxes = new WeakMap<WebSocket, Record<string, any>[]>();
const waiters = new WeakMap<WebSocket, ((value: Record<string, any>) => void)[]>();

function connect(): Promise<WebSocket> {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(`ws://127.0.0.1:${port}/ws`);
    inboxes.set(socket, []);
    waiters.set(socket, []);
    socket.on("message", (raw) => {
      const value = JSON.parse(raw.toString());
      const waiter = waiters.get(socket)?.shift();
      if (waiter) waiter(value); else inboxes.get(socket)?.push(value);
    });
    socket.once("open", () => resolve(socket));
    socket.once("error", reject);
  });
}

function receive(socket: WebSocket): Promise<Record<string, any>> {
  const queued = inboxes.get(socket)?.shift();
  if (queued) return Promise.resolve(queued);
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("message timeout")), 3_000);
    waiters.get(socket)?.push((value) => { clearTimeout(timer); resolve(value); });
  });
}

function send(socket: WebSocket, type: string, payload: object, id?: string): void {
  socket.send(JSON.stringify({ type, protocolVersion, payload, ...(id ? { id } : {}) }));
}

async function receiveType(socket: WebSocket, type: string): Promise<Record<string, any>> {
  for (let attempt = 0; attempt < 10; attempt++) {
    const value = await receive(socket);
    if (value.type === type) return value;
  }
  throw new Error(`did not receive ${type}`);
}

before(async () => {
  directory = await mkdtemp(join(tmpdir(), "vipi-test-"));
  port = await availablePort();
  child = spawn(process.execPath, ["--import", "tsx", "host/src/server.ts"], {
    cwd: process.cwd(),
    env: { ...process.env, PI_CODING_AGENT_DIR: directory, VIPI_PORT: String(port), VIPI_HOST: "127.0.0.1" },
    stdio: ["ignore", "pipe", "pipe"],
  });
  await new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("host startup timeout")), 5_000);
    child.once("exit", (code) => reject(new Error(`host exited ${code}`)));
    child.stdout?.on("data", (data) => {
      hostOutput += data.toString();
      if (data.toString().includes("Vipi host listening")) { clearTimeout(timer); resolve(); }
    });
  });
  token = (await readFile(join(directory, "vipi", "token"), "utf8")).trim();
  assert.equal((await stat(join(directory, "vipi", "token"))).mode & 0o777, 0o600);
});

after(async () => {
  child.kill("SIGTERM");
  await rm(directory, { recursive: true, force: true });
});

test("creates pairing payloads only for public HTTPS Tailscale hosts", () => {
  assert.deepEqual(createPairingPayload("https://vipi-mac.example-tailnet.ts.net/", "token"), {
    host: "https://vipi-mac.example-tailnet.ts.net", token: "token",
  });
  assert.throws(() => createPairingPayload(undefined, "token"), /VIPI_PUBLIC_URL is required/);
  assert.throws(() => createPairingPayload("http://127.0.0.1:8765", "token"), /HTTPS/);
  assert.throws(() => createPairingPayload("https://public.example.com", "token"), /.ts.net/);
});

test("normalizes final messages and redacts tool payloads from mobile DTOs", () => {
  const message = { role: "assistant", content: [{ type: "text", text: "hello" }], timestamp: 1_700_000_000_000 };
  assert.deepEqual(normalizeMessage(message, "m1", true), {
    kind: "message", messageID: "m1", role: "assistant", text: "hello",
    timestamp: "2023-11-14T22:13:20.000Z", streaming: true,
  });
  const tool = normalizeToolEvent({ type: "tool_execution_end", toolCallId: "t1", toolName: "read", result: "ok", isError: false });
  assert.equal(tool?.kind, "progress");
  assert.equal(tool?.kind === "progress" ? tool.activity : undefined, "thinking");
  assert.equal("detail" in (tool ?? {}), false);
  const history = normalizeHistory([
    { id: "e1", parentId: null, timestamp: "2026-08-24T00:00:00Z", type: "message", message: { role: "user", content: "first", timestamp: 1 } },
    { id: "e2", parentId: "e1", timestamp: "2026-08-24T00:00:01Z", type: "message", message: {
      role: "assistant", timestamp: 2, api: "anthropic-messages", provider: "anthropic", model: "test", stopReason: "toolUse",
      usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
      content: [{ type: "text", text: "second" }, { type: "toolCall", id: "call-1", name: "read", arguments: { path: "README.md" } }],
    } },
    { id: "e3", parentId: "e2", timestamp: "2026-08-24T00:00:02Z", type: "message", message: {
      role: "toolResult", toolCallId: "call-1", toolName: "read", content: [{ type: "text", text: "file body" }], isError: false, timestamp: 3,
    } },
    { id: "e4", parentId: "e3", timestamp: "2026-08-24T00:00:03Z", type: "message", message: {
      role: "assistant", content: [{ type: "text", text: "final answer" }], timestamp: 4,
    } },
  ], { afterEntryID: "e1" });
  assert.equal(history.events.length, 1);
  assert.equal(history.events[0]?.kind, "message");
  assert.equal(history.events[0]?.kind === "message" ? history.events[0].text : undefined, "final answer");
  assert.equal(JSON.stringify(history).includes("file body"), false);
  assert.equal(JSON.stringify(history).includes("README.md"), false);
  assert.equal(history.lastEntryID, "e4");
  assert.equal(history.oldestEntryID, "e2");
  assert.equal(history.hasMore, false);
});

test("bounds large real histories below the WebSocket payload limit", () => {
  const entries = Array.from({ length: 80 }, (_, index) => ({
    id: `large-${index}`,
    type: "message",
    message: {
      role: index % 2 === 0 ? "user" : "assistant",
      content: [{ type: "text", text: `${index}: ${"한글 history ".repeat(4_000)}` }],
      timestamp: index + 1,
    },
  }));
  const history = normalizeHistory(entries);
  assert.ok(Buffer.byteLength(JSON.stringify(history), "utf8") < 512 * 1024);
  assert.equal(history.lastEntryID, "large-79");
  const latestEvent = history.events.at(-1);
  assert.equal(latestEvent?.kind === "message" ? latestEvent.entryID : undefined, "large-79");
  assert.ok(history.events.length < entries.length);
  assert.equal(history.hasMore, true);

  const older = normalizeHistory(entries, { beforeEntryID: history.oldestEntryID, limit: 20 });
  assert.ok(older.events.length > 0);
  assert.ok(older.events.every((event) => event.kind !== "message" || event.entryID !== history.oldestEntryID));
});

test("reads the active JSONL branch without becoming a writer", () => {
  const file = join(directory, "branch.jsonl");
  writeFileSync(file, [
    JSON.stringify({ type: "session", version: 3 }),
    JSON.stringify({ id: "root", parentId: null, type: "message", message: { role: "user", content: "root", timestamp: 1 } }),
    JSON.stringify({ id: "old", parentId: "root", type: "message", message: { role: "assistant", content: "old branch", timestamp: 2 } }),
    JSON.stringify({ id: "active", parentId: "root", type: "message", message: { role: "assistant", content: "active branch", timestamp: 3 } }),
    "{partial",
  ].join("\n"));
  assert.deepEqual(readSessionBranch(file).map((entry) => entry.id), ["root", "active"]);
});

test("replays missed normalized runtime events from a sequence cursor", async () => {
  const runtime = await connect();
  send(runtime, "runtime.register", { token, session: {
    id: "session-1", name: "Test", cwd: "/tmp/test", phase: "idle", unread: false,
    lastActivityAt: new Date().toISOString(), model: "Pi", thinkingLevel: "off", contextPercent: 0,
    tmux: { session: "test", window: "1", paneID: "%1" },
  } });

  const mobile = await connect();
  send(mobile, "auth.authenticate", { token }, "auth-1");
  const auth = await receive(mobile);
  assert.equal(auth.type, "auth.ok");
  const snapshot = await receive(mobile);
  assert.equal(snapshot.type, "sessions.snapshot");

  const eventOne = { sessionID: "session-1", event: { kind: "progress", activity: "thinking", timestamp: new Date().toISOString() } };
  send(runtime, "runtime.event", eventOne);
  const first = await receive(mobile);
  assert.equal(first.type, "session.event");
  assert.equal(first.payload.event.activity, "thinking");
  const cursor = first.seq as number;
  mobile.close();
  await new Promise((resolve) => mobile.once("close", resolve));

  send(runtime, "runtime.event", { ...eventOne, event: { ...eventOne.event, activity: "editing" } });
  const resumed = await connect();
  send(resumed, "auth.authenticate", { token, lastSeq: cursor }, "auth-2");
  assert.equal((await receive(resumed)).type, "auth.ok");
  const replayed = await receive(resumed);
  assert.equal(replayed.type, "session.event");
  assert.equal(replayed.payload.event.activity, "editing");
  assert.ok(replayed.seq > cursor);
  resumed.close();
  runtime.close();
});

test("resets stale state when reconnect cursor is above the broker head", async () => {
  const mobile = await connect();
  send(mobile, "auth.authenticate", { token, lastSeq: 1_000_000 }, "future-cursor-auth");
  assert.equal((await receive(mobile)).type, "auth.ok");
  const snapshot = await receive(mobile);
  assert.equal(snapshot.type, "sessions.snapshot");
  assert.equal(snapshot.payload.replayReset, true);
  assert.ok(Array.isArray(snapshot.payload.sessions));
  mobile.close();
});

test("routes prompt modes, abort, history, responses, and tool events", async () => {
  const runtime = await connect();
  send(runtime, "runtime.register", { token, session: {
    id: "controls", name: "Controls", cwd: "/tmp/controls", phase: "working", unread: false,
    lastActivityAt: new Date().toISOString(), model: "Pi", thinkingLevel: "medium", contextPercent: 10,
    tmux: { session: "controls", window: "1", paneID: "%2" },
  } });
  const mobile = await connect();
  send(mobile, "auth.authenticate", { token }, "controls-auth");
  await receive(mobile);
  await receive(mobile);

  for (const [index, command] of [
    ["session.prompt", { sessionID: "controls", text: "prompt", delivery: "prompt" }],
    ["session.prompt", { sessionID: "controls", text: "steer", delivery: "steer" }],
    ["session.prompt", { sessionID: "controls", text: "follow", delivery: "followUp" }],
    ["session.abort", { sessionID: "controls" }],
    ["session.compact", { sessionID: "controls" }],
    ["session.history", { sessionID: "controls", afterEntryID: "entry-1" }],
  ].entries()) {
    const id = `request-${index}`;
    send(mobile, command[0] as string, command[1] as object, id);
    const forwarded = await receive(runtime);
    assert.equal(forwarded.type, command[0]);
    assert.equal(forwarded.id, id);
    send(runtime, "runtime.response", { requestID: id, ok: true, result: command[0] === "session.history" ? { events: [], lastEntryID: "entry-2" } : undefined });
    const response = await receive(mobile);
    assert.equal(response.type, "session.response");
    assert.equal(response.id, id);
    assert.equal(response.payload.ok, true);
  }

  send(runtime, "runtime.event", { sessionID: "controls", event: {
    kind: "tool", toolCallID: "tool-1", name: "read", state: "running", summary: "read running",
  } });
  const tool = await receive(mobile);
  assert.equal(tool.type, "session.event");
  assert.equal(tool.payload.event.kind, "progress");
  assert.equal(tool.payload.event.activity, "reading");
  assert.equal(tool.payload.event.detail, undefined);
  mobile.close();
  runtime.close();
});

test("uses the session tree as the exact visibility boundary and derives missing previews", async () => {
  const registryPath = join(directory, "tmux-session-tree.json");
  const sessionFile = join(directory, "visible-session.jsonl");
  writeFileSync(sessionFile, [
    JSON.stringify({ type: "session", version: 3 }),
    JSON.stringify({ id: "visible-user", parentId: null, type: "message", message: { role: "user", content: "preview request", timestamp: 1 } }),
    JSON.stringify({ id: "visible-answer", parentId: "visible-user", type: "message", message: { role: "assistant", content: "preview answer", timestamp: 2 } }),
  ].join("\n"));
  writeFileSync(registryPath, JSON.stringify({ entries: [{
    piSessionId: "visible-session", name: "Visible", cwd: "/tmp/visible",
    status: "idle", unread: true, tmuxSession: "visible", tmuxWindow: "1", tmuxPaneId: "%new",
    lastSeen: new Date().toISOString(), sessionFile,
  }] }));

  const stale = await connect();
  const staleClosed = new Promise<number>((resolve) => stale.once("close", (code) => resolve(code)));
  send(stale, "runtime.register", { token, session: {
    id: "visible-session", name: "Stale", cwd: "/tmp/visible", phase: "idle", unread: false,
    lastActivityAt: new Date().toISOString(), model: "Pi", thinkingLevel: "off", contextPercent: 0,
    tmux: { session: "visible", window: "old", paneID: "%old" },
  } });
  assert.equal(await staleClosed, 4009);

  const active = await connect();
  send(active, "runtime.register", { token, session: {
    id: "visible-session", name: "Visible", cwd: "/tmp/visible", phase: "idle", unread: false,
    lastActivityAt: new Date().toISOString(), model: "Pi", thinkingLevel: "off", contextPercent: 0,
    tmux: { session: "visible", window: "1", paneID: "%new" },
  } });
  const mobile = await connect();
  send(mobile, "auth.authenticate", { token }, "visible-auth");
  await receiveType(mobile, "auth.ok");
  const visibleSnapshot = await receiveType(mobile, "sessions.snapshot");
  assert.deepEqual(visibleSnapshot.payload.sessions.map((session: { id: string }) => session.id), ["visible-session"]);
  assert.equal(visibleSnapshot.payload.sessions[0].lastMessagePreview, "preview answer");
  assert.equal(visibleSnapshot.payload.sessions[0].unread, true);

  send(mobile, "session.read", { sessionID: "visible-session" }, "visible-read");
  const readResponse = await receiveType(mobile, "session.response");
  assert.equal(readResponse.payload.ok, true);
  const forwardedRead = await receive(active);
  assert.equal(forwardedRead.type, "session.read");
  const mobileReadSnapshot = await receiveType(mobile, "sessions.snapshot");
  assert.equal(mobileReadSnapshot.payload.sessions[0].unread, false);
  const persistedRead = JSON.parse(await readFile(registryPath, "utf8"));
  assert.equal(persistedRead.entries[0].unread, false);

  persistedRead.entries[0].unread = true;
  writeFileSync(registryPath, JSON.stringify(persistedRead));
  const treeUnreadSnapshot = await receiveType(mobile, "sessions.snapshot");
  assert.equal(treeUnreadSnapshot.payload.sessions[0].unread, true);
  persistedRead.entries[0].unread = false;
  writeFileSync(registryPath, JSON.stringify(persistedRead));
  const treeReadSnapshot = await receiveType(mobile, "sessions.snapshot");
  assert.equal(treeReadSnapshot.payload.sessions[0].unread, false);

  send(mobile, "session.prompt", { sessionID: "visible-session", text: "visible prompt", delivery: "prompt" }, "visible-prompt");
  const forwarded = await receive(active);
  assert.equal(forwarded.id, "visible-prompt");
  assert.equal(forwarded.payload.text, "visible prompt");

  await rm(registryPath, { force: true });
  const deletedSnapshot = await receiveType(mobile, "sessions.snapshot");
  assert.deepEqual(deletedSnapshot.payload.sessions, []);
  mobile.close();
  active.close();
});

test("allows sustained lightweight progress events above the mobile command rate", async () => {
  const runtime = await connect();
  send(runtime, "runtime.register", { token, session: {
    id: "sustained", name: "Sustained", cwd: "/tmp/sustained", phase: "working", unread: false,
    lastActivityAt: new Date().toISOString(), model: "Pi", thinkingLevel: "medium", contextPercent: 1,
    tmux: { session: "sustained", window: "1", paneID: "%3" },
  } });
  const mobile = await connect();
  send(mobile, "auth.authenticate", { token }, "sustained-auth");
  await receiveType(mobile, "auth.ok");
  await receiveType(mobile, "sessions.snapshot");
  for (let index = 0; index < 250; index++) {
    send(runtime, "runtime.event", { sessionID: "sustained", event: {
      kind: "progress", activity: index % 2 === 0 ? "thinking" : "editing",
      timestamp: new Date().toISOString(),
    } });
  }
  let last: Record<string, any> | undefined;
  for (let index = 0; index < 250; index++) last = await receiveType(mobile, "session.event");
  assert.equal(last?.payload.event.activity, "editing");
  assert.equal(runtime.readyState, WebSocket.OPEN);
  mobile.close();
  runtime.close();
});

test("still rate limits authenticated mobile command abuse", async () => {
  const mobile = await connect();
  send(mobile, "auth.authenticate", { token }, "limited-auth");
  await receiveType(mobile, "auth.ok");
  await receiveType(mobile, "sessions.snapshot");
  const closed = new Promise<number>((resolve) => mobile.once("close", (code) => resolve(code)));
  for (let index = 0; index < 140; index++) send(mobile, "sessions.list", {}, `list-${index}`);
  assert.equal(await closed, 4008);
});

test("runs the real Pi extension through broker registration, history, controls, streaming, and tools", async () => {
  process.env.PI_CODING_AGENT_DIR = directory;
  process.env.VIPI_BROKER_URL = `ws://127.0.0.1:${port}/ws`;
  const handlers = new Map<string, (event: any, context: ExtensionContext) => Promise<void>>();
  const delivered: Array<{ text: string; delivery?: string }> = [];
  let aborted = false;
  let compacted = false;
  const branch: any[] = [
    { id: "real-1", parentId: null, timestamp: "2026-08-24T00:00:00Z", type: "message", message: { role: "user", content: "real history", timestamp: 1 } },
    { id: "real-2", parentId: "real-1", timestamp: "2026-08-24T00:00:01Z", type: "message", message: { role: "toolResult", toolCallId: "real-tool", toolName: "read", content: [{ type: "text", text: "result" }], isError: false, timestamp: 2 } },
  ];
  const realSessionFile = join(directory, "real-extension.jsonl");
  writeFileSync(realSessionFile, branch.map((entry) => JSON.stringify(entry)).join("\n"));
  const context = {
    cwd: "/tmp/real-extension",
    model: { id: "fixture-model", name: "Fixture Model" },
    sessionManager: {
      getSessionId: () => "real-extension",
      getSessionFile: () => realSessionFile,
      getBranch: () => branch,
    },
    getContextUsage: () => ({ percent: 25 }),
    abort: () => { aborted = true; },
    compact: () => { compacted = true; },
  } as unknown as ExtensionContext;
  const emitted: Array<{ name: string; payload: unknown }> = [];
  const api = {
    on: (name: string, handler: (event: any, ctx: ExtensionContext) => Promise<void>) => { handlers.set(name, handler); },
    events: { emit: (name: string, payload: unknown) => emitted.push({ name, payload }) },
    getSessionName: () => "Real / Extension",
    getThinkingLevel: () => "medium",
    sendUserMessage: (text: string, options?: { deliverAs?: string }) => delivered.push({ text, ...(options?.deliverAs ? { delivery: options.deliverAs } : {}) }),
  } as unknown as ExtensionAPI;
  writeFileSync(join(directory, "tmux-session-tree.json"), JSON.stringify({ entries: [{
    piSessionId: "real-extension", name: "Real / Extension", cwd: context.cwd,
    status: "idle", tmuxSession: "fixture", tmuxWindow: "1", tmuxPaneId: process.env.TMUX_PANE ?? "",
    lastSeen: new Date().toISOString(), sessionFile: context.sessionManager.getSessionFile(),
  }] }));
  const extension = (await import("../../extension/index.js")).default;
  extension(api);
  await handlers.get("session_start")?.({ type: "session_start", reason: "startup" }, context);

  const mobile = await connect();
  send(mobile, "auth.authenticate", { token }, "real-auth");
  await receiveType(mobile, "auth.ok");
  let snapshot = await receiveType(mobile, "sessions.snapshot");
  while (snapshot.payload.sessions.find((session: { id: string }) => session.id === "real-extension")?.phase === "offline") {
    snapshot = await receiveType(mobile, "sessions.snapshot");
  }
  assert.ok(snapshot.payload.sessions.some((session: { id: string }) => session.id === "real-extension"));

  send(mobile, "session.read", { sessionID: "real-extension" }, "real-read");
  assert.equal((await receiveType(mobile, "session.response")).payload.ok, true);
  for (let attempt = 0; attempt < 20 && emitted.length === 0; attempt++) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  assert.deepEqual(emitted, [{ name: "vipi:session-read", payload: { sessionID: "real-extension" } }]);

  send(mobile, "session.history", { sessionID: "real-extension" }, "real-history");
  const history = await receiveType(mobile, "session.response");
  assert.equal(history.payload.result.events[0].text, "real history");
  assert.equal(history.payload.result.events.length, 1);
  assert.equal(JSON.stringify(history.payload.result).includes("result"), false);

  for (const [id, delivery] of [["prompt", "prompt"], ["steer", "steer"], ["follow", "followUp"]] as const) {
    send(mobile, "session.prompt", { sessionID: "real-extension", text: id, delivery }, `real-${id}`);
    await receiveType(mobile, "session.response");
  }
  assert.deepEqual(delivered, [{ text: "prompt" }, { text: "steer", delivery: "steer" }, { text: "follow", delivery: "followUp" }]);
  send(mobile, "session.abort", { sessionID: "real-extension" }, "real-abort");
  await receiveType(mobile, "session.response");
  send(mobile, "session.compact", { sessionID: "real-extension" }, "real-compact");
  await receiveType(mobile, "session.response");
  assert.equal(aborted, true);
  assert.equal(compacted, true);

  await handlers.get("agent_start")?.({ type: "agent_start" }, context);
  const thinking = await receiveType(mobile, "session.event");
  assert.equal(thinking.payload.event.activity, "thinking");
  await handlers.get("tool_execution_start")?.({ type: "tool_execution_start", toolCallId: "live-tool", toolName: "edit", args: { path: "/secret", content: "large private content" } }, context);
  const editing = await receiveType(mobile, "session.event");
  assert.equal(editing.payload.event.activity, "editing");
  assert.equal(JSON.stringify(editing).includes("large private content"), false);
  await handlers.get("tool_execution_end")?.({ type: "tool_execution_end", toolCallId: "live-tool", toolName: "edit", result: "private result", isError: false }, context);
  const thinkingAgain = await receiveType(mobile, "session.event");
  assert.equal(thinkingAgain.payload.event.activity, "thinking");

  const assistant = { role: "assistant", content: [{ type: "text", text: "live real extension" }], timestamp: Date.now() };
  branch.push({ id: "real-live-entry", parentId: "real-2", timestamp: new Date().toISOString(), type: "message", message: assistant });
  await handlers.get("message_end")?.({ type: "message_end", message: assistant }, context);
  await handlers.get("agent_settled")?.({ type: "agent_settled" }, context);
  const settled = await receiveType(mobile, "session.event");
  assert.equal(settled.payload.event.messageID, "real-live-entry");
  assert.equal(settled.payload.event.text, "live real extension");
  await handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "quit" }, context);
  mobile.close();
});

test("rotates tokens atomically, revokes peers, and does not log bearer secrets", async () => {
  assert.equal(hostOutput.includes(token), false);
  const owner = await connect();
  send(owner, "auth.authenticate", { token }, "owner-auth");
  await receive(owner);
  await receive(owner);
  const peer = await connect();
  send(peer, "auth.authenticate", { token }, "peer-auth");
  await receive(peer);
  await receive(peer);
  const peerClosed = new Promise<number>((resolve) => peer.once("close", (code) => resolve(code)));

  send(owner, "auth.rotate", {}, "rotate-1");
  const rotated = await receiveType(owner, "auth.rotated");
  const previous = token;
  token = rotated.payload.token;
  assert.notEqual(token, previous);
  assert.equal(await peerClosed, 4001);
  const stored = (await readFile(join(directory, "vipi", "token"), "utf8")).trim();
  assert.equal(stored, token);

  const rejected = await connect();
  send(rejected, "auth.authenticate", { token: previous }, "old-auth");
  assert.equal(await new Promise<number>((resolve) => rejected.once("close", (code) => resolve(code))), 4001);
  owner.close();
});
