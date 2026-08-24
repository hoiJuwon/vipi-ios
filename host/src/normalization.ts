export type ChatRole = "user" | "assistant" | "system";

export type NormalizedSessionEvent =
  | { kind: "message"; messageID: string; role: ChatRole; text: string; timestamp: string; streaming: boolean; entryID?: string }
  | { kind: "tool"; toolCallID: string; name: string; state: "running" | "succeeded" | "failed"; summary: string; detail?: string; entryID?: string };

type UnknownRecord = Record<string, unknown>;

function record(value: unknown): UnknownRecord | undefined {
  return value !== null && typeof value === "object" ? value as UnknownRecord : undefined;
}

function textContent(value: unknown): string {
  if (typeof value === "string") return value;
  if (!Array.isArray(value)) return "";
  return value.flatMap((part) => {
    const item = record(part);
    if (!item) return [];
    if (item.type === "text" && typeof item.text === "string") return [item.text];
    if (item.type === "thinking" && typeof item.thinking === "string") return [];
    return [];
  }).join("");
}

function timestamp(value: unknown): string {
  if (typeof value === "number" && Number.isFinite(value)) return new Date(value).toISOString();
  if (typeof value === "string" && !Number.isNaN(Date.parse(value))) return new Date(value).toISOString();
  return new Date().toISOString();
}

function safeDetail(value: unknown): string | undefined {
  if (value === undefined) return undefined;
  const raw = typeof value === "string" ? value : JSON.stringify(value);
  return raw.length > 4_096 ? `${raw.slice(0, 4_096)}…` : raw;
}

export function normalizeMessage(messageValue: unknown, messageID: string, streaming: boolean, entryID?: string): NormalizedSessionEvent | undefined {
  const message = record(messageValue);
  if (!message) return undefined;
  const role = message.role;
  if (role !== "user" && role !== "assistant" && role !== "system") return undefined;
  return {
    kind: "message",
    messageID,
    role,
    text: textContent(message.content),
    timestamp: timestamp(message.timestamp),
    streaming,
    ...(entryID ? { entryID } : {}),
  };
}

export function normalizeToolEvent(eventValue: unknown, entryID?: string): NormalizedSessionEvent | undefined {
  const event = record(eventValue);
  if (!event) return undefined;
  const toolCallID = event.toolCallId;
  const name = event.toolName;
  if (typeof toolCallID !== "string" || typeof name !== "string") return undefined;
  const type = event.type;
  const failed = type === "tool_execution_end" && event.isError === true;
  const state = type === "tool_execution_end" ? (failed ? "failed" : "succeeded") : "running";
  const source = type === "tool_execution_start" ? event.args : type === "tool_execution_update" ? event.partialResult : event.result;
  return {
    kind: "tool",
    toolCallID,
    name,
    state,
    summary: state === "running" ? `${name} running` : failed ? `${name} failed` : `${name} completed`,
    ...(safeDetail(source) ? { detail: safeDetail(source) } : {}),
    ...(entryID ? { entryID } : {}),
  };
}

export function normalizeHistory(entriesValue: unknown, afterEntryID?: string): { events: NormalizedSessionEvent[]; lastEntryID?: string } {
  if (!Array.isArray(entriesValue)) return { events: [] };
  const entries = entriesValue.map(record).filter((entry): entry is UnknownRecord => Boolean(entry));
  const start = afterEntryID ? entries.findIndex((entry) => entry.id === afterEntryID) + 1 : 0;
  const selected = afterEntryID && start === 0 ? entries : entries.slice(start);
  const events: NormalizedSessionEvent[] = [];
  for (const entry of selected) {
    const entryID = typeof entry.id === "string" ? entry.id : undefined;
    if (entry.type === "message") {
      const normalized = normalizeMessage(entry.message, entryID ?? `history-${events.length}`, false, entryID);
      if (normalized) events.push(normalized);
      continue;
    }
    const tool = normalizeToolEvent(entry, entryID);
    if (tool) events.push(tool);
  }
  const last = entries.at(-1)?.id;
  return { events, ...(typeof last === "string" ? { lastEntryID: last } : {}) };
}
