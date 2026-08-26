import { createHash } from "node:crypto";

export type ChatRole = "user" | "assistant";
export type MobileActivity = "thinking" | "reading" | "editing" | "running" | "searching";

export type NormalizedSessionEvent =
  | { kind: "message"; messageID: string; role: ChatRole; text: string; timestamp: string; streaming: boolean; attachments?: ImageAttachment[]; entryID?: string; replacesMessageID?: string }
  | { kind: "progress"; activity: MobileActivity; timestamp: string };

type UnknownRecord = Record<string, unknown>;
type ImageAttachment = { id: string; mimeType: string };

function record(value: unknown): UnknownRecord | undefined {
  return value !== null && typeof value === "object" ? value as UnknownRecord : undefined;
}

function textContent(value: unknown): string {
  if (typeof value === "string") return value;
  if (!Array.isArray(value)) return "";
  return value.flatMap((part) => {
    const item = record(part);
    return item?.type === "text" && typeof item.text === "string" ? [item.text] : [];
  }).join("");
}

function imageAttachments(value: unknown): ImageAttachment[] {
  if (!Array.isArray(value)) return [];
  return value.slice(0, 4).flatMap((part): ImageAttachment[] => {
    const item = record(part);
    const source = record(item?.source);
    const data = typeof item?.data === "string"
      ? item.data
      : source?.type === "base64" && typeof source.data === "string" ? source.data : undefined;
    const mimeType = typeof item?.mimeType === "string"
      ? item.mimeType
      : typeof source?.mediaType === "string" ? source.mediaType : undefined;
    if (item?.type !== "image" || !data || !mimeType?.startsWith("image/")) return [];
    return [{ id: createHash("sha256").update(data, "base64").digest("hex"), mimeType }];
  });
}

function timestamp(value: unknown): string {
  if (typeof value === "number" && Number.isFinite(value)) return new Date(value).toISOString();
  if (typeof value === "string" && !Number.isNaN(Date.parse(value))) return new Date(value).toISOString();
  return new Date().toISOString();
}

function hasToolCall(message: UnknownRecord): boolean {
  return Array.isArray(message.content) && message.content.some((part) => record(part)?.type === "toolCall");
}

export function normalizeMessage(
  messageValue: unknown,
  messageID: string,
  streaming: boolean,
  entryID?: string,
  replacesMessageID?: string,
): NormalizedSessionEvent | undefined {
  const message = record(messageValue);
  if (!message || (message.role !== "user" && message.role !== "assistant") || hasToolCall(message)) return undefined;
  const text = textContent(message.content);
  const attachments = message.role === "user" ? imageAttachments(message.content) : [];
  if (message.role === "user" && (text.startsWith("[GOAL CONFIRMATION") || text.startsWith("[GOAL TWEAK DRAFT]"))) return undefined;
  if (!text.trim() && attachments.length === 0) return undefined;
  return {
    kind: "message",
    messageID,
    role: message.role,
    text,
    timestamp: timestamp(message.timestamp),
    streaming,
    ...(attachments.length > 0 ? { attachments } : {}),
    ...(entryID ? { entryID } : {}),
    ...(replacesMessageID ? { replacesMessageID } : {}),
  };
}

export function mobileActivityForTool(name: string): MobileActivity {
  const value = name.toLowerCase();
  if (["edit", "write", "apply_patch"].some((token) => value.includes(token))) return "editing";
  if (["read", "grep", "find", "glob", "ls"].some((token) => value.includes(token))) return "reading";
  if (["search", "web", "fetch", "browse"].some((token) => value.includes(token))) return "searching";
  return "running";
}

export function normalizeToolEvent(eventValue: unknown): NormalizedSessionEvent | undefined {
  const event = record(eventValue);
  const name = event?.toolName;
  if (typeof name !== "string") return undefined;
  return {
    kind: "progress",
    activity: event?.type === "tool_execution_end" ? "thinking" : mobileActivityForTool(name),
    timestamp: new Date().toISOString(),
  };
}

function finalMessageIndexes(entries: UnknownRecord[]): Set<number> {
  const result = new Set<number>();
  let turnStart = 0;
  for (let end = 0; end <= entries.length; end++) {
    const role = end < entries.length && entries[end]?.type === "message"
      ? record(entries[end]?.message)?.role
      : undefined;
    if (end < entries.length && role !== "user") continue;

    const turnEnd = end;
    const assistantCandidates: number[] = [];
    for (let index = turnStart; index < turnEnd; index++) {
      const entry = entries[index];
      const message = entry?.type === "message" ? record(entry.message) : undefined;
      if (message?.role === "assistant" && textContent(message.content).trim() && !hasToolCall(message)) {
        assistantCandidates.push(index);
      }
    }
    if (assistantCandidates.length > 0) result.add(assistantCandidates.at(-1)!);
    turnStart = end;
  }
  return result;
}

const HISTORY_PAYLOAD_BUDGET = 384 * 1024;

function recentEventsWithinBudget(events: NormalizedSessionEvent[]): NormalizedSessionEvent[] {
  const selected: NormalizedSessionEvent[] = [];
  let bytes = 2;
  for (let index = events.length - 1; index >= 0; index -= 1) {
    let event = events[index]!;
    if (event.kind === "message" && Buffer.byteLength(event.text, "utf8") > 64 * 1024) {
      event = { ...event, text: `${event.text.slice(0, 32 * 1024)}\n…[older content truncated on mobile]` };
    }
    const eventBytes = Buffer.byteLength(JSON.stringify(event), "utf8") + 1;
    if (selected.length > 0 && bytes + eventBytes > HISTORY_PAYLOAD_BUDGET) break;
    selected.push(event);
    bytes += eventBytes;
  }
  return selected.reverse();
}

export interface HistoryOptions {
  afterEntryID?: string;
  beforeEntryID?: string;
  limit?: number;
}

export interface NormalizedHistory {
  events: NormalizedSessionEvent[];
  lastEntryID?: string;
  oldestEntryID?: string;
  hasMore: boolean;
}

export function normalizeHistory(entriesValue: unknown, options: HistoryOptions = {}): NormalizedHistory {
  if (!Array.isArray(entriesValue)) return { events: [], hasMore: false };
  const entries = entriesValue.map(record).filter((entry): entry is UnknownRecord => Boolean(entry));
  const limit = Math.min(120, Math.max(20, options.limit ?? 60));
  const afterIndex = options.afterEntryID ? entries.findIndex((entry) => entry.id === options.afterEntryID) : -1;
  const beforeIndex = options.beforeEntryID ? entries.findIndex((entry) => entry.id === options.beforeEntryID) : -1;

  let start = 0;
  let end = entries.length;
  if (options.afterEntryID && afterIndex >= 0) {
    start = afterIndex + 1;
  } else {
    end = options.beforeEntryID && beforeIndex >= 0 ? beforeIndex : entries.length;
    start = Math.max(0, end - limit);
    if (!options.beforeEntryID) {
      const latestUser = entries.slice(0, end).findLastIndex((entry) => entry.type === "message" && record(entry.message)?.role === "user");
      if (latestUser >= 0) start = Math.min(start, latestUser);
    }
  }

  const selected = entries.slice(start, end);
  const finalAssistants = finalMessageIndexes(selected);
  const events: NormalizedSessionEvent[] = [];
  for (const [index, entry] of selected.entries()) {
    if (entry.type !== "message") continue;
    const message = record(entry.message);
    const role = message?.role;
    if (role !== "user" && !(role === "assistant" && finalAssistants.has(index))) continue;
    const entryID = typeof entry.id === "string" ? entry.id : `history-entry-${index}`;
    const normalized = normalizeMessage(message, entryID, false, entryID);
    if (normalized) events.push(normalized);
  }

  const last = entries.at(-1)?.id;
  const oldest = selected.at(0)?.id;
  return {
    events: recentEventsWithinBudget(events),
    ...(typeof last === "string" ? { lastEntryID: last } : {}),
    ...(typeof oldest === "string" ? { oldestEntryID: oldest } : {}),
    hasMore: !options.afterEntryID && start > 0,
  };
}
