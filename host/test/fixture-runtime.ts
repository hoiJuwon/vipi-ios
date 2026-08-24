import WebSocket from "ws";

const token = process.env.VIPI_FIXTURE_TOKEN;
const port = process.env.VIPI_PORT ?? "8765";
if (!token) throw new Error("VIPI_FIXTURE_TOKEN is required");
const socket = new WebSocket(`ws://127.0.0.1:${port}/ws`);
const envelope = (type: string, payload: unknown) => JSON.stringify({ type, protocolVersion: 1, payload });
const session = {
  id: "e2e", name: "E2E / Live session", cwd: "/tmp/vipi-e2e", phase: "idle", unread: false,
  lastActivityAt: new Date().toISOString(), model: "Fixture", thinkingLevel: "medium", contextPercent: 12,
  tmux: { session: "vipi-e2e", window: "1", paneID: "%99" },
};
socket.on("open", () => socket.send(envelope("runtime.register", { token, session })));
socket.on("message", (raw) => {
  const message = JSON.parse(raw.toString()) as { id?: string; type: string; payload?: Record<string, unknown> };
  const respond = (result?: unknown) => socket.send(envelope("runtime.response", { requestID: message.id, ok: true, result }));
  if (message.type === "session.history") {
    respond({ events: [{
      kind: "message", messageID: "history-1", role: "assistant", text: "History restored",
      timestamp: new Date().toISOString(), streaming: false, entryID: "entry-1",
    }], lastEntryID: "entry-1" });
  } else if (message.type === "session.prompt") {
    respond();
    socket.send(envelope("runtime.event", { sessionID: "e2e", event: {
      kind: "message", messageID: "live-1", role: "assistant", text: "Streaming",
      timestamp: new Date().toISOString(), streaming: true,
    } }));
    socket.send(envelope("runtime.event", { sessionID: "e2e", event: {
      kind: "tool", toolCallID: "tool-e2e", name: "read", state: "succeeded", summary: "read completed",
    } }));
    socket.send(envelope("runtime.event", { sessionID: "e2e", event: {
      kind: "message", messageID: "live-1", role: "assistant", text: "Streaming complete",
      timestamp: new Date().toISOString(), streaming: false,
    } }));
  } else if (message.type === "session.abort") {
    respond({ aborted: true });
  }
});
