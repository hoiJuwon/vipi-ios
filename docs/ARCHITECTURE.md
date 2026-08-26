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

The device token is defense in depth in addition to tailnet membership. The app persists it as a this-device-only Keychain item and supports authenticated rotation. The host enforces loopback binding by default, rate limits sockets, never logs payloads or bearer values, and is intended to sit behind tailnet-only Tailscale Serve. Commands are allowlisted and correlated without opening a second session writer. Remote folder browsing resolves canonical directories and is limited to the host user's home directory plus explicitly registered workspace roots.

## Protocol evolution

Every envelope carries `protocolVersion`. Unknown event types are ignored by the app. Durable reconnect uses monotonically increasing `seq` with a host-side bounded replay buffer. Full and incremental history are normalized into user messages and final assistant answers only. Tool calls, `toolResult` entries, arguments, partial output, results, compaction summaries, and system messages are discarded before the mobile history DTO is encoded. Live tools are reduced at the extension/host boundary to a small progress category without payload content.

Assistant excerpts selected with `Add to Chat` travel only with the next `session.prompt`. The extension injects them as a non-displayed custom context message in `before_agent_start`, while the persisted user message remains the user's clean draft. This preserves the single-writer invariant and prevents annotation markup from leaking into mobile or terminal transcript bubbles.

Blocking extension interactions (`confirm`, `select`, and `input`) are bridged only while an authenticated mobile socket is present. Requests are ephemeral rather than replayed, responses are correlated to the originating runtime, and disconnect or timeout falls back to the original terminal UI. This prevents stale permission requests from reappearing after reconnect.

Photo attachments use an authenticated `POST /attachments` endpoint on the existing loopback host through the same Tailscale Serve origin. iOS downsamples and re-encodes selected photos before upload, strips source metadata, and sends only short-lived attachment IDs in the WebSocket prompt. The host stores each upload as a private temporary file, binds it to one session, verifies its SHA-256 digest, and deletes it after runtime acceptance or expiry. The existing Pi extension converts the file to Pi `ImageContent` and calls `pi.sendUserMessage`, so the tmux Pi process remains the only JSONL writer. Mobile history receives only image digests and MIME types, never the base64 payload.

Authenticated `session.create` starts a brand-new regular Pi process in a tmux window at the selected canonical directory. The host writes the same provisional registry row used by `pi-session-tree`, then releases a short startup gate so the session-tree extension atomically replaces it with Pi's real session ID and JSONL path. This creates a new writer rather than attaching a second writer to any existing JSONL session.

Answer-completion alerts use direct APNs HTTP/2 delivery from the loopback host. iOS registers a sandbox or production device token only after notification permission is granted and transmits it over the authenticated Vipi socket. The host stores tokens in a private `0600` file, signs short-lived ES256 provider JWTs from a local `.p8` key, removes APNs-expired devices, and sends only a session name plus generic completion text on the exact `working → completed` transition. Tapping an alert routes to the corresponding session after the registry snapshot is available.

## Deliberate future scope

Offline saved-session ownership remains out of scope. It requires an explicit ownership lease before any second process may resume a JSONL session.
