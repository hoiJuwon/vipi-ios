import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import vipiBridge from "../../extension/index.js";

const handlers = new Map<string, (event: any, context: ExtensionContext) => Promise<void>>();
let phase = "idle";
let nextEntry = 2;
const branch: any[] = [{
  id: "entry-1", parentId: null, timestamp: new Date().toISOString(), type: "message",
  message: { role: "assistant", content: [{ type: "text", text: "History restored" }], timestamp: Date.now() - 1_000 },
}];

const context = {
  cwd: "/tmp/vipi-e2e",
  model: { id: "fixture", name: "Fixture" },
  sessionManager: {
    getSessionId: () => "e2e",
    getSessionFile: () => "/tmp/vipi-e2e.jsonl",
    getBranch: () => branch,
  },
  getContextUsage: () => ({ percent: 12 }),
  abort: () => {},
  compact: () => {},
} as unknown as ExtensionContext;

async function produceSettledTurn(): Promise<void> {
  phase = "working";
  await handlers.get("agent_start")?.({ type: "agent_start" }, context);
  const message: any = { role: "assistant", content: [{ type: "text", text: "Streaming" }], timestamp: Date.now() };
  await handlers.get("message_start")?.({ type: "message_start", message }, context);
  await handlers.get("message_update")?.({ type: "message_update", message, assistantMessageEvent: { type: "text_delta", delta: "Streaming" } }, context);
  await handlers.get("tool_execution_end")?.({ type: "tool_execution_end", toolCallId: "tool-e2e", toolName: "read", result: "ok", isError: false }, context);
  message.content = [
    { type: "text", text: "Streaming complete" },
    { type: "toolCall", id: "tool-e2e", name: "read", arguments: { path: "README.md" } },
  ];
  const messageEntryID = `entry-${nextEntry++}`;
  branch.push({ id: messageEntryID, parentId: branch.at(-1)?.id ?? null, timestamp: new Date().toISOString(), type: "message", message });
  await handlers.get("message_end")?.({ type: "message_end", message }, context);
  branch.push({
    id: `entry-${nextEntry++}`, parentId: messageEntryID, timestamp: new Date().toISOString(), type: "message",
    message: { role: "toolResult", toolCallId: "tool-e2e", toolName: "read", content: [{ type: "text", text: "ok" }], isError: false, timestamp: Date.now() },
  });
  phase = "completed";
  await handlers.get("agent_settled")?.({ type: "agent_settled" }, context);
}

const api = {
  on: (name: string, handler: (event: any, ctx: ExtensionContext) => Promise<void>) => { handlers.set(name, handler); },
  getSessionName: () => "E2E / Live session",
  getThinkingLevel: () => "medium",
  sendUserMessage: () => { setTimeout(() => void produceSettledTurn(), 10); },
} as unknown as ExtensionAPI;

vipiBridge(api);
await handlers.get("session_start")?.({ type: "session_start", reason: "startup" }, context);

process.on("SIGTERM", async () => {
  await handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "quit" }, context);
  process.exit(0);
});
