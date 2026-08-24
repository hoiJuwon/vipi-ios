export type ChatRole = "user" | "assistant" | "system";

export type NormalizedSessionEvent =
  | { kind: "message"; messageID: string; role: ChatRole; text: string; timestamp: string; streaming: boolean; entryID?: string; replacesMessageID?: string }
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

export function normalizeMessage(
  messageValue: unknown,
  messageID: string,
  streaming: boolean,
  entryID?: string,
  replacesMessageID?: string,
): NormalizedSessionEvent | undefined {
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
    ...(replacesMessageID ? { replacesMessageID } : {}),
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

function normalizeHistoryMessage(messageValue: unknown, entryID: string, index: number): NormalizedSessionEvent[] {
  const message = record(messageValue);
  if (!message) return [];
  if (message.role === "toolResult") {
    const toolCallID = message.toolCallId;
    const name = message.toolName;
    if (typeof toolCallID !== "string" || typeof name !== "string") return [];
    return [{
      kind: "tool",
      toolCallID,
      name,
      state: message.isError === true ? "failed" : "succeeded",
      summary: message.isError === true ? `${name} failed` : `${name} completed`,
      ...(safeDetail(textContent(message.content)) ? { detail: safeDetail(textContent(message.content)) } : {}),
      entryID,
    }];
  }

  const events: NormalizedSessionEvent[] = [];
  const normalized = normalizeMessage(message, entryID || `history-${index}`, false, entryID);
  if (normalized) events.push(normalized);
  if (message.role === "assistant" && Array.isArray(message.content)) {
    for (const partValue of message.content) {
      const part = record(partValue);
      if (part?.type !== "toolCall" || typeof part.id !== "string" || typeof part.name !== "string") continue;
      events.push({
        kind: "tool",
        toolCallID: part.id,
        name: part.name,
        state: "running",
        summary: `${part.name} running`,
        ...(safeDetail(part.arguments) ? { detail: safeDetail(part.arguments) } : {}),
        entryID,
      });
    }
  }
  return events;
}

export function normalizeHistory(entriesValue: unknown, afterEntryID?: string): { events: NormalizedSessionEvent[]; lastEntryID?: string } {
  if (!Array.isArray(entriesValue)) return { events: [] };
  const entries = entriesValue.map(record).filter((entry): entry is UnknownRecord => Boolean(entry));
  const cursorIndex = afterEntryID ? entries.findIndex((entry) => entry.id === afterEntryID) : -1;
  const selected = afterEntryID && cursorIndex >= 0 ? entries.slice(cursorIndex + 1) : entries;
  const events: NormalizedSessionEvent[] = [];
  for (const [index, entry] of selected.entries()) {
    const entryID = typeof entry.id === "string" ? entry.id : `history-entry-${index}`;
    if (entry.type === "message") {
      events.push(...normalizeHistoryMessage(entry.message, entryID, index));
      continue;
    }
    if ((entry.type === "compaction" || entry.type === "branch_summary") && typeof entry.summary === "string") {
      events.push({ kind: "message", messageID: entryID, role: "system", text: entry.summary, timestamp: timestamp(entry.timestamp), streaming: false, entryID });
    }
  }
  const last = entries.at(-1)?.id;
  return { events, ...(typeof last === "string" ? { lastEntryID: last } : {}) };
}
