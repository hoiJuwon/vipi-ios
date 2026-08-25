# Vipi architecture

## Product boundary

Vipi is a semantic chat client, not a remote terminal. Vim editing, EX commands, tmux pane operations, and terminal rendering stay on the host. The mobile app receives normalized session and agent events.

## Identity

A session is keyed by Pi's stable `sessionId`. Runtime metadata may additionally include `tmuxSession`, `tmuxWindow`, and `tmuxPaneId`, but those coordinates are diagnostic and must not become user-facing identity.

## Ownership invariant

A live JSONL session has exactly one writer: the Pi process already running in tmux. Mobile commands are delivered into that process through its extension. Vipi must not start `pi --mode rpc --session <same-file>` while the terminal process is alive.

Future offline resume can use an RPC worker only after acquiring an explicit mobile ownership lease and confirming that no connected runtime owns the session.

## Trust boundary

```text
Tailnet device
  → Tailscale HTTPS/WSS
  → loopback broker
  → authenticated runtime socket
  → Pi extension API
  → user account tools/files
```

The device token is defense in depth in addition to tailnet membership. The app persists it as a this-device-only Keychain item and supports authenticated rotation. The host enforces loopback binding by default, rate limits sockets, never logs payloads or bearer values, and is intended to sit behind tailnet-only Tailscale Serve. Commands are allowlisted and correlated without opening a second session writer.

## Protocol evolution

Every envelope carries `protocolVersion`. Unknown event types are ignored by the app. Durable reconnect uses monotonically increasing `seq` with a host-side bounded replay buffer. Full and incremental history are normalized into user messages and final assistant answers only. Tool calls, `toolResult` entries, arguments, partial output, results, compaction summaries, and system messages are discarded before the mobile history DTO is encoded. Live tools are reduced at the extension/host boundary to a small progress category without payload content.

Assistant excerpts selected with `Add to Chat` travel only with the next `session.prompt`. The extension injects them as a non-displayed custom context message in `before_agent_start`, while the persisted user message remains the user's clean draft. This preserves the single-writer invariant and prevents annotation markup from leaking into mobile or terminal transcript bubbles.

## Deliberate future scope

Offline saved-session ownership and blocking extension UI cards are not exposed as controls in this release. They require explicit ownership leases and a separately designed mobile interaction protocol; placeholder controls are intentionally absent.
