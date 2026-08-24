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

The device token is defense in depth in addition to tailnet membership. Production hardening still needs Keychain persistence in the app, token rotation/pairing UI, Tailscale identity verification, request rate limits, command auditing, and payload redaction.

## Protocol evolution

Every envelope carries `protocolVersion`. Unknown event types are ignored by the app. Durable reconnect will use monotonically increasing `seq` and a host-side bounded replay buffer. Full history is recovered from the active extension's `SessionManager` rather than replaying terminal pixels.

## Next implementation slices

1. Normalize Pi `message_update`, `message_end`, and tool events into typed chat deltas.
2. Implement `session.history` reducer and reconnect using last entry ID.
3. Add QR pairing and Keychain-backed token storage.
4. Add model/thinking/compact/rename commands.
5. Add blocking extension UI cards for select, confirm, input, and editor.
6. Add offline saved-session catalog and ownership-gated RPC workers.
7. Add launchd service setup and verified Tailscale Serve identity.
