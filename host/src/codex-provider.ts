import { randomUUID } from "node:crypto";
import { basename } from "node:path";
import { CodexClient, type CodexConnectionState } from "./codex-client.js";
import type { SessionPhase, SessionRecord } from "./protocol.js";

type JsonObject = Record<string, unknown>;
type NormalizedEvent =
  | { kind: "message"; messageID: string; role: "user" | "assistant"; text: string; timestamp: string; streaming: boolean; entryID?: string }
  | { kind: "progress"; activity: "thinking" | "reading" | "editing" | "running" | "searching"; timestamp: string };

interface CodexThread {
  id: string;
  name?: string | null;
  preview?: string | null;
  cwd?: string | null;
  modelProvider?: string | null;
  updatedAt?: number | null;
  createdAt?: number | null;
  status?: { type?: string; activeFlags?: string[] } | null;
}

interface CodexProviderCallbacks {
  onStateChange?: (state: CodexConnectionState, detail?: string) => void;
  onSessionsChanged?: () => void;
  onEvent?: (sessionID: string, event: NormalizedEvent) => void;
  onInteraction?: (interaction: {
    requestID: string;
    sessionID: string;
    kind: "confirm";
    title: string;
    message: string;
  }) => void;
}

type PendingApproval = { rpcID: string | number; method: string; threadID: string; params: JsonObject };

const CODEX_PREFIX = "codex:";
const CURSOR_PREFIX = "codex-cursor:";

function object(value: unknown): JsonObject | undefined {
  return value !== null && typeof value === "object" ? value as JsonObject : undefined;
}

function epochDate(value: unknown): string {
  if (typeof value !== "number" || !Number.isFinite(value)) return new Date().toISOString();
  return new Date(value > 10_000_000_000 ? value : value * 1_000).toISOString();
}

function statusPhase(status: CodexThread["status"]): SessionPhase {
  if (status?.type === "active") {
    return status.activeFlags?.some((flag) => flag === "waitingOnApproval" || flag === "waitingOnUserInput")
      ? "waitingForInput" : "working";
  }
  if (status?.type === "systemError") return "failed";
  return "idle";
}

function textFromUserContent(value: unknown): string {
  if (!Array.isArray(value)) return "";
  return value.flatMap((part): string[] => {
    const item = object(part);
    return item?.type === "text" && typeof item.text === "string" ? [item.text] : [];
  }).join("\n");
}

export function normalizeCodexThread(thread: CodexThread, unread = false): SessionRecord {
  const cwd = typeof thread.cwd === "string" && thread.cwd ? thread.cwd : "~";
  const preview = typeof thread.preview === "string" ? thread.preview.replace(/&#x20;/g, " ").trim() : "";
  const name = typeof thread.name === "string" && thread.name.trim()
    ? thread.name.trim()
    : preview ? preview.slice(0, 60) : `${basename(cwd) || "Codex"} / New session`;
  return {
    id: `${CODEX_PREFIX}${thread.id}`,
    provider: "codex",
    name,
    cwd,
    phase: statusPhase(thread.status),
    unread,
    lastActivityAt: epochDate(thread.updatedAt ?? thread.createdAt),
    ...(preview ? { lastMessagePreview: preview } : {}),
    model: "Codex",
    thinkingLevel: "—",
    contextPercent: 0,
    tmux: { session: "", window: "", paneID: `${CODEX_PREFIX}${thread.id}` },
  };
}

export function normalizeCodexTurns(turnsValue: unknown): NormalizedEvent[] {
  if (!Array.isArray(turnsValue)) return [];
  const events: NormalizedEvent[] = [];
  for (const turnValue of [...turnsValue].reverse()) {
    const turn = object(turnValue);
    if (!turn) continue;
    const items = Array.isArray(turn.items) ? turn.items.map(object).filter((item): item is JsonObject => Boolean(item)) : [];
    const timestamp = epochDate(turn.startedAt ?? turn.completedAt);
    const user = items.find((item) => item.type === "userMessage");
    const userText = textFromUserContent(user?.content);
    if (user && userText.trim()) {
      events.push({
        kind: "message",
        messageID: `codex-item:${String(user.id ?? turn.id ?? randomUUID())}`,
        role: "user",
        text: userText,
        timestamp,
        streaming: false,
        entryID: String(turn.id ?? user.id ?? ""),
      });
    }
    const assistants = items.filter((item) => item.type === "agentMessage" && typeof item.text === "string" && item.text.trim());
    const assistant = assistants.at(-1);
    if (assistant) {
      events.push({
        kind: "message",
        messageID: `codex-item:${String(assistant.id ?? turn.id ?? randomUUID())}`,
        role: "assistant",
        text: String(assistant.text),
        timestamp: epochDate(turn.completedAt ?? turn.startedAt),
        streaming: false,
        entryID: String(turn.id ?? assistant.id ?? ""),
      });
    }
  }
  return events;
}

export class CodexProvider {
  private readonly client: CodexClient;
  private readonly callbacks: CodexProviderCallbacks;
  private readonly sessionRecords = new Map<string, SessionRecord>();
  private readonly threadLoadState = new Map<string, string>();
  private readonly unread = new Set<string>();
  private readonly activeTurns = new Map<string, string>();
  private readonly pendingApprovals = new Map<string, PendingApproval>();
  private refreshTimer?: NodeJS.Timeout;
  private refreshQueued = false;
  private sessionsFingerprint = "";
  state: CodexConnectionState = "disconnected";
  detail?: string;

  constructor(callbacks: CodexProviderCallbacks = {}) {
    this.callbacks = callbacks;
    this.client = new CodexClient({
      onNotification: (method, params) => this.receiveNotification(method, params),
      onServerRequest: (id, method, params) => this.receiveServerRequest(id, method, params),
      onStateChange: (state, detail) => this.connectionChanged(state, detail),
    });
  }

  start(): void {
    if (process.env.VIPI_CODEX_ENABLED === "0") return;
    this.client.start();
  }

  stop(): void {
    if (this.refreshTimer) clearInterval(this.refreshTimer);
    this.client.stop();
  }

  sessions(): SessionRecord[] {
    return [...this.sessionRecords.values()].sort((a, b) => b.lastActivityAt.localeCompare(a.lastActivityAt));
  }

  hasSession(sessionID: string): boolean {
    return sessionID.startsWith(CODEX_PREFIX) && this.sessionRecords.has(sessionID);
  }

  async refreshSessions(): Promise<void> {
    if (this.state !== "connected") return;
    const result = await this.client.request<{ data?: CodexThread[] }>("thread/list", {
      limit: 100,
      sortKey: "updated_at",
      sortDirection: "desc",
      useStateDbOnly: true,
    });
    const next = new Map<string, SessionRecord>();
    for (const thread of result.data ?? []) {
      if (!thread?.id) continue;
      const id = `${CODEX_PREFIX}${thread.id}`;
      next.set(id, normalizeCodexThread(thread, this.unread.has(id)));
      this.threadLoadState.set(id, thread.status?.type ?? "notLoaded");
    }
    const fingerprint = JSON.stringify([...next.values()]);
    this.sessionRecords.clear();
    for (const [id, session] of next) this.sessionRecords.set(id, session);
    if (fingerprint !== this.sessionsFingerprint) {
      this.sessionsFingerprint = fingerprint;
      this.callbacks.onSessionsChanged?.();
    }
  }

  async history(sessionID: string, options: { beforeEntryID?: string; limit?: number }): Promise<{
    events: NormalizedEvent[];
    lastEntryID: string;
    oldestEntryID?: string;
    hasMore: boolean;
  }> {
    const threadID = this.threadID(sessionID);
    const cursor = options.beforeEntryID?.startsWith(CURSOR_PREFIX)
      ? options.beforeEntryID.slice(CURSOR_PREFIX.length) : undefined;
    const result = await this.client.request<{ data?: unknown[]; nextCursor?: string | null }>("thread/turns/list", {
      threadId: threadID,
      limit: Math.min(30, Math.max(5, Math.ceil((options.limit ?? 60) / 2))),
      sortDirection: "desc",
      itemsView: "full",
      ...(cursor ? { cursor } : {}),
    }, 20_000);
    const events = normalizeCodexTurns(result.data);
    const session = this.sessionRecords.get(sessionID);
    return {
      events,
      lastEntryID: `codex-update:${session?.lastActivityAt ?? Date.now()}`,
      ...(result.nextCursor ? { oldestEntryID: `${CURSOR_PREFIX}${result.nextCursor}` } : {}),
      hasMore: Boolean(result.nextCursor),
    };
  }

  async create(cwd: string): Promise<{ cwd: string; paneID: string; sessionID: string }> {
    const result = await this.client.request<{ thread?: CodexThread }>("thread/start", { cwd }, 20_000);
    if (!result.thread?.id) throw new Error("Codex did not create a thread");
    const session = normalizeCodexThread(result.thread);
    this.sessionRecords.set(session.id, session);
    this.threadLoadState.set(session.id, result.thread.status?.type ?? "idle");
    this.callbacks.onSessionsChanged?.();
    return { cwd: session.cwd, paneID: session.tmux.paneID, sessionID: session.id };
  }

  async prompt(payload: JsonObject): Promise<void> {
    const sessionID = String(payload.sessionID ?? "");
    const threadID = this.threadID(sessionID);
    const text = typeof payload.text === "string" ? payload.text : "";
    const delivery = payload.delivery === "followUp" ? "followUp" : "prompt";
    const attachments = Array.isArray(payload.attachments) ? payload.attachments.map(object).filter((item): item is JsonObject => Boolean(item)) : [];
    const input: JsonObject[] = [];
    if (text.trim()) input.push({ type: "text", text });
    for (const attachment of attachments.slice(0, 4)) {
      if (typeof attachment.path === "string") input.push({ type: "localImage", path: attachment.path });
    }
    if (input.length === 0) throw new Error("A prompt or image is required");

    const status = this.sessionRecords.get(sessionID)?.phase;
    if (delivery === "followUp" && status === "working") {
      await this.client.request("turn/steer", {
        threadId: threadID,
        input,
        ...(typeof payload.clientMessageID === "string" ? { clientUserMessageId: payload.clientMessageID } : {}),
      });
      return;
    }
    if (status === "offline") throw new Error("Codex is unavailable");
    if (this.threadLoadState.get(sessionID) === "notLoaded") {
      await this.client.request("thread/resume", { threadId: threadID }, 20_000);
      this.threadLoadState.set(sessionID, "idle");
    }
    await this.client.request("turn/start", {
      threadId: threadID,
      input,
      ...(typeof payload.clientMessageID === "string" ? { clientUserMessageId: payload.clientMessageID } : {}),
    });
  }

  async abort(sessionID: string): Promise<void> {
    const turnID = this.activeTurns.get(sessionID);
    if (!turnID) throw new Error("Codex has no active turn to stop");
    await this.client.request("turn/interrupt", { threadId: this.threadID(sessionID), turnId: turnID });
  }

  async compact(sessionID: string): Promise<void> {
    await this.client.request("thread/compact/start", { threadId: this.threadID(sessionID) });
  }

  markRead(sessionID: string): void {
    this.unread.delete(sessionID);
    const session = this.sessionRecords.get(sessionID);
    if (session) session.unread = false;
    this.callbacks.onSessionsChanged?.();
  }

  respondToInteraction(requestID: string, allow: boolean): boolean {
    const pending = this.pendingApprovals.get(requestID);
    if (!pending) return false;
    this.pendingApprovals.delete(requestID);
    if (pending.method === "item/permissions/requestApproval") {
      this.client.respond(pending.rpcID, {
        permissions: allow && object(pending.params.permissions) ? pending.params.permissions : {},
        scope: "turn",
      });
    } else {
      this.client.respond(pending.rpcID, { decision: allow ? "accept" : "decline" });
    }
    return true;
  }

  private connectionChanged(state: CodexConnectionState, detail?: string): void {
    this.state = state;
    this.detail = detail;
    if (state === "connected") {
      void this.refreshSessions().catch((error) => {
        this.detail = error instanceof Error ? error.message : "Codex refresh failed";
        this.callbacks.onStateChange?.(this.state, this.detail);
      });
      if (!this.refreshTimer) {
        this.refreshTimer = setInterval(() => void this.refreshSessions().catch(() => {}), 5_000);
        this.refreshTimer.unref();
      }
    } else if (this.refreshTimer) {
      clearInterval(this.refreshTimer);
      this.refreshTimer = undefined;
    }
    this.callbacks.onStateChange?.(state, detail);
  }

  private receiveNotification(method: string, params: JsonObject): void {
    const threadID = typeof params.threadId === "string"
      ? params.threadId
      : object(params.thread)?.threadId as string | undefined;
    const sessionID = threadID ? `${CODEX_PREFIX}${threadID}` : undefined;

    if (method === "turn/started") {
      const turn = object(params.turn);
      const resolvedThreadID = typeof turn?.threadId === "string" ? turn.threadId : threadID;
      const id = typeof turn?.id === "string" ? turn.id : undefined;
      if (resolvedThreadID && id) this.activeTurns.set(`${CODEX_PREFIX}${resolvedThreadID}`, id);
      if (resolvedThreadID) {
        this.threadLoadState.set(`${CODEX_PREFIX}${resolvedThreadID}`, "active");
        this.updatePhase(`${CODEX_PREFIX}${resolvedThreadID}`, "working");
      }
    } else if (method === "turn/completed") {
      const turn = object(params.turn);
      const resolvedThreadID = typeof turn?.threadId === "string" ? turn.threadId : threadID;
      if (resolvedThreadID) {
        const resolvedSessionID = `${CODEX_PREFIX}${resolvedThreadID}`;
        this.activeTurns.delete(resolvedSessionID);
        this.threadLoadState.set(resolvedSessionID, "idle");
        const status = turn?.status === "failed" ? "failed" : "completed";
        this.updatePhase(resolvedSessionID, status);
        const items = Array.isArray(turn?.items) ? turn.items : [];
        const events = normalizeCodexTurns([{ ...turn, items }]);
        for (const event of events.filter((candidate) => candidate.kind === "message" && candidate.role === "assistant")) {
          this.callbacks.onEvent?.(resolvedSessionID, event);
        }
        this.unread.add(resolvedSessionID);
      }
    } else if (method === "item/started" && sessionID) {
      const item = object(params.item);
      const type = item?.type;
      const activity = type === "fileChange" ? "editing"
        : type === "commandExecution" ? "running"
          : type === "webSearch" ? "searching"
            : type === "mcpToolCall" ? "running" : "thinking";
      this.callbacks.onEvent?.(sessionID, { kind: "progress", activity, timestamp: new Date().toISOString() });
    } else if (method === "thread/status/changed" && sessionID) {
      const status = object(params.status) as CodexThread["status"];
      this.threadLoadState.set(sessionID, status?.type ?? "notLoaded");
      this.updatePhase(sessionID, statusPhase(status));
    }

    if (method.startsWith("thread/") || method.startsWith("turn/")) this.queueRefresh();
  }

  private receiveServerRequest(id: string | number, method: string, params: JsonObject): void {
    const approvalMethods = new Set([
      "item/commandExecution/requestApproval",
      "item/fileChange/requestApproval",
      "item/permissions/requestApproval",
    ]);
    if (!approvalMethods.has(method)) {
      if (method === "mcpServer/elicitation/request") this.client.respond(id, { action: "decline", content: null });
      else if (method === "item/tool/requestUserInput") this.client.respond(id, { answers: {} });
      else this.client.respond(id, { decision: "decline" });
      return;
    }
    const threadID = typeof params.threadId === "string" ? params.threadId : undefined;
    if (!threadID) {
      this.client.respond(id, { decision: "decline" });
      return;
    }
    const requestID = `codex-approval:${String(id)}`;
    this.pendingApprovals.set(requestID, { rpcID: id, method, threadID, params });
    this.updatePhase(`${CODEX_PREFIX}${threadID}`, "waitingForInput");
    this.callbacks.onInteraction?.({
      requestID,
      sessionID: `${CODEX_PREFIX}${threadID}`,
      kind: "confirm",
      title: "Codex needs permission",
      message: method === "item/fileChange/requestApproval"
        ? "Allow Codex to apply the proposed file changes?"
        : method === "item/permissions/requestApproval"
          ? "Codex requested additional access. Denying keeps the current access unchanged."
          : "Allow Codex to continue this action?",
    });
  }

  private updatePhase(sessionID: string, phase: SessionPhase): void {
    const session = this.sessionRecords.get(sessionID);
    if (session) {
      session.phase = phase;
      session.lastActivityAt = new Date().toISOString();
    }
    this.callbacks.onSessionsChanged?.();
  }

  private queueRefresh(): void {
    if (this.refreshQueued) return;
    this.refreshQueued = true;
    setTimeout(() => {
      this.refreshQueued = false;
      void this.refreshSessions().catch(() => {});
    }, 150).unref();
  }

  private threadID(sessionID: string): string {
    if (!sessionID.startsWith(CODEX_PREFIX)) throw new Error("Not a Codex session");
    return sessionID.slice(CODEX_PREFIX.length);
  }
}
