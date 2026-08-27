export const PROTOCOL_VERSION = 1;

export type SessionPhase = "idle" | "working" | "waitingForInput" | "completed" | "failed" | "offline";

export type AgentProvider = "pi" | "codex";

export interface SessionRecord {
  id: string;
  provider?: AgentProvider;
  name: string;
  cwd: string;
  phase: SessionPhase;
  unread: boolean;
  lastActivityAt: string;
  lastMessagePreview?: string;
  model: string;
  thinkingLevel: string;
  branch?: string;
  contextPercent: number;
  tmux: { session: string; window: string; paneID: string };
  sessionFile?: string;
}

export interface Envelope<T = unknown> {
  id?: string;
  type: string;
  protocolVersion: number;
  seq?: number;
  payload: T;
}

export function envelope<T>(type: string, payload: T, id?: string, seq?: number): Envelope<T> {
  return { id, type, protocolVersion: PROTOCOL_VERSION, seq, payload };
}
