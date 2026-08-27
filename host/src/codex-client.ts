import { homedir } from "node:os";
import { join } from "node:path";
import WebSocket from "ws";

type JsonObject = Record<string, unknown>;
type PendingRequest = {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
};

export type CodexConnectionState = "connecting" | "connected" | "disconnected";

export interface CodexClientOptions {
  socketPath?: string;
  onNotification?: (method: string, params: JsonObject) => void;
  onServerRequest?: (id: string | number, method: string, params: JsonObject) => void;
  onStateChange?: (state: CodexConnectionState, detail?: string) => void;
}

/**
 * Small, allowlist-friendly JSON-RPC client for Codex's local app-server control socket.
 * It never reads Codex databases, rollout JSONL, or credentials directly.
 */
export class CodexClient {
  readonly socketPath: string;
  private socket?: WebSocket;
  private nextID = 1;
  private readonly pending = new Map<number, PendingRequest>();
  private reconnectTimer?: NodeJS.Timeout;
  private stopped = false;
  private reconnectAttempt = 0;

  constructor(private readonly options: CodexClientOptions = {}) {
    this.socketPath = options.socketPath
      ?? process.env.VIPI_CODEX_SOCKET
      ?? join(process.env.CODEX_HOME ?? join(homedir(), ".codex"), "app-server-control", "app-server-control.sock");
  }

  start(): void {
    this.stopped = false;
    void this.connect();
  }

  stop(): void {
    this.stopped = true;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.reconnectTimer = undefined;
    this.socket?.close();
    this.socket = undefined;
    this.rejectPending(new Error("Codex connection stopped"));
  }

  async request<T = unknown>(method: string, params: JsonObject = {}, timeoutMs = 15_000): Promise<T> {
    const socket = this.socket;
    if (!socket || socket.readyState !== WebSocket.OPEN) throw new Error("Codex is not connected");
    const id = this.nextID++;
    return await new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Codex request timed out: ${method}`));
      }, timeoutMs);
      timer.unref();
      this.pending.set(id, {
        resolve: (value) => resolve(value as T),
        reject,
        timer,
      });
      socket.send(JSON.stringify({ id, method, params }), (error) => {
        if (!error) return;
        const pending = this.pending.get(id);
        if (!pending) return;
        clearTimeout(pending.timer);
        this.pending.delete(id);
        pending.reject(error);
      });
    });
  }

  respond(id: string | number, result: JsonObject): void {
    if (this.socket?.readyState === WebSocket.OPEN) {
      this.socket.send(JSON.stringify({ id, result }));
    }
  }

  private async connect(): Promise<void> {
    if (this.stopped || this.socket?.readyState === WebSocket.OPEN || this.socket?.readyState === WebSocket.CONNECTING) return;
    this.options.onStateChange?.("connecting");
    const socketURL = `ws+unix://${this.socketPath}:/`;
    // Codex pages are bounded, but a single summarized turn can still contain
    // local image metadata. Keep a finite per-page ceiling without accepting
    // an unbounded legacy transcript.
    const socket = new WebSocket(socketURL, { perMessageDeflate: false, maxPayload: 64 * 1024 * 1024 });
    this.socket = socket;

    socket.on("message", (raw) => this.receive(raw.toString()));
    socket.on("error", () => {});
    socket.on("close", () => {
      if (this.socket !== socket) return;
      this.socket = undefined;
      this.rejectPending(new Error("Codex disconnected"));
      this.options.onStateChange?.("disconnected", "Codex app-server is unavailable");
      this.scheduleReconnect();
    });

    try {
      await new Promise<void>((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error("Codex connection timed out")), 5_000);
        socket.once("open", () => { clearTimeout(timer); resolve(); });
        socket.once("error", (error) => { clearTimeout(timer); reject(error); });
      });
      await this.request("initialize", {
        clientInfo: { name: "vipi_ios", title: "Vipi", version: "0.1.0" },
        capabilities: { experimentalApi: true },
      });
      socket.send(JSON.stringify({ method: "initialized", params: {} }));
      this.reconnectAttempt = 0;
      this.options.onStateChange?.("connected");
    } catch (error) {
      socket.close();
      if (this.socket === socket) this.socket = undefined;
      this.options.onStateChange?.("disconnected", error instanceof Error ? error.message : "Codex connection failed");
      this.scheduleReconnect();
    }
  }

  private receive(raw: string): void {
    let message: JsonObject;
    try { message = JSON.parse(raw) as JsonObject; } catch { return; }
    const id = message.id;
    const method = typeof message.method === "string" ? message.method : undefined;
    if (typeof id === "number" && !method) {
      const pending = this.pending.get(id);
      if (!pending) return;
      clearTimeout(pending.timer);
      this.pending.delete(id);
      const error = message.error as JsonObject | undefined;
      if (error) pending.reject(new Error(typeof error.message === "string" ? error.message : "Codex request failed"));
      else pending.resolve(message.result);
      return;
    }
    const params = message.params && typeof message.params === "object" ? message.params as JsonObject : {};
    if (method && (typeof id === "number" || typeof id === "string")) {
      this.options.onServerRequest?.(id, method, params);
    } else if (method) {
      this.options.onNotification?.(method, params);
    }
  }

  private rejectPending(error: Error): void {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
  }

  private scheduleReconnect(): void {
    if (this.stopped || this.reconnectTimer) return;
    const delay = Math.min(30_000, 1_000 * 2 ** Math.min(this.reconnectAttempt++, 5));
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = undefined;
      void this.connect();
    }, delay);
    this.reconnectTimer.unref();
  }
}
