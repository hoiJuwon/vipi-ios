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
    getSessionFile: () => process.env.VIPI_FIXTURE_SESSION_FILE ?? "/tmp/vipi-e2e.jsonl",
    getBranch: () => branch,
  },
  getContextUsage: () => ({ percent: 12 }),
  abort: () => {},
  compact: () => {},
} as unknown as ExtensionContext;

async function produceSettledTurn(): Promise<void> {
  phase = "working";
  await handlers.get("agent_start")?.({ type: "agent_start" }, context);
  await handlers.get("tool_execution_start")?.({ type: "tool_execution_start", toolCallId: "tool-e2e", toolName: "read", args: { path: "README.md" } }, context);
  await handlers.get("tool_execution_end")?.({ type: "tool_execution_end", toolCallId: "tool-e2e", toolName: "read", result: "ok", isError: false }, context);
  const message: any = { role: "assistant", content: [{ type: "text", text: "Streaming complete" }], timestamp: Date.now() };
  const messageEntryID = `entry-${nextEntry++}`;
  branch.push({ id: messageEntryID, parentId: branch.at(-1)?.id ?? null, timestamp: new Date().toISOString(), type: "message", message });
  await handlers.get("message_end")?.({ type: "message_end", message }, context);
  phase = "completed";
  await handlers.get("agent_settled")?.({ type: "agent_settled" }, context);
}

const api = {
  on: (name: string, handler: (event: any, ctx: ExtensionContext) => Promise<void>) => { handlers.set(name, handler); },
  events: { emit: () => {} },
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
