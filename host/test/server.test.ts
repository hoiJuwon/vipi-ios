import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, test } from "node:test";
import WebSocket from "ws";
import { normalizeHistory, normalizeMessage, normalizeToolEvent } from "../src/normalization.js";

const protocolVersion = 1;
let child: ChildProcess;
let directory: string;
let port: number;
let token: string;

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
      if (data.toString().includes("Vipi host listening")) { clearTimeout(timer); resolve(); }
    });
  });
  token = (await readFile(join(directory, "vipi", "token"), "utf8")).trim();
});

after(async () => {
  child.kill("SIGTERM");
  await rm(directory, { recursive: true, force: true });
});

test("normalizes message, tool, and incremental branch history", () => {
  const message = { role: "assistant", content: [{ type: "text", text: "hello" }], timestamp: 1_700_000_000_000 };
  assert.deepEqual(normalizeMessage(message, "m1", true), {
    kind: "message", messageID: "m1", role: "assistant", text: "hello",
    timestamp: "2023-11-14T22:13:20.000Z", streaming: true,
  });
  const tool = normalizeToolEvent({ type: "tool_execution_end", toolCallId: "t1", toolName: "read", result: "ok", isError: false });
  assert.equal(tool?.kind, "tool");
  assert.equal(tool?.kind === "tool" ? tool.state : undefined, "succeeded");
  const history = normalizeHistory([
    { id: "e1", type: "message", message: { role: "user", content: "first", timestamp: 1 } },
    { id: "e2", type: "message", message: { role: "assistant", content: [{ type: "text", text: "second" }], timestamp: 2 } },
  ], "e1");
  assert.equal(history.events.length, 1);
  assert.equal(history.events[0]?.entryID, "e2");
  assert.equal(history.lastEntryID, "e2");
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

  const eventOne = { sessionID: "session-1", event: { kind: "message", messageID: "m1", role: "assistant", text: "A", timestamp: new Date().toISOString(), streaming: true } };
  send(runtime, "runtime.event", eventOne);
  const first = await receive(mobile);
  assert.equal(first.type, "session.event");
  assert.equal(first.payload.event.text, "A");
  const cursor = first.seq as number;
  mobile.close();
  await new Promise((resolve) => mobile.once("close", resolve));

  send(runtime, "runtime.event", { ...eventOne, event: { ...eventOne.event, text: "AB" } });
  const resumed = await connect();
  send(resumed, "auth.authenticate", { token, lastSeq: cursor }, "auth-2");
  assert.equal((await receive(resumed)).type, "auth.ok");
  const replayed = await receive(resumed);
  assert.equal(replayed.type, "session.event");
  assert.equal(replayed.payload.event.text, "AB");
  assert.ok(replayed.seq > cursor);
  resumed.close();
  runtime.close();
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
  assert.equal(tool.payload.event.kind, "tool");
  mobile.close();
  runtime.close();
});
