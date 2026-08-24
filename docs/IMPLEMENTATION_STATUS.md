# Implementation status

Baseline recorded 2026-08-24.

## Passing baseline

- `npm run check` passes TypeScript type checking.
- `xcodebuild ... test` passes the two existing Swift unit tests on the Vipi iPhone simulator (iOS 26.5).
- `main` initially matched `origin/main` at `59592a9`.

## Gaps against the completion objective

### Host and extension

- Runtime events are forwarded as raw Pi event objects rather than a stable normalized protocol.
- Sequence numbers are process-global only; there is no bounded replay buffer, resume cursor, or incremental reconnect.
- History returns raw branch entries and is not reduced into typed chat/tool records.
- Runtime command responses are broadcast rather than correlated to the requesting mobile client.
- No WebSocket integration tests, rate limiting, command audit trail, payload redaction, token rotation, or launchd installer exists.
- The host prints the bearer token and embeds it in a terminal QR, which is unsuitable for hardened operation.

### iOS

- The token lives only in observable memory; there is no Keychain persistence or pairing/rotation workflow.
- Connection state becomes connected before `auth.ok`, and there is no reconnect/backoff or sequence resume.
- The store only reduces authentication and session snapshots; history, streaming deltas, tool events, responses, and errors are not implemented.
- Controls suppress transport errors; compact/model/thinking controls are placeholders.
- Accessibility identifiers and an XCUITest target are absent.

### QA and release

- Existing tests cover only mock grouping/data (two unit tests).
- No host integration tests, protocol reducer tests, Keychain tests, UI tests, or simulator end-to-end evidence exists.
- Archive/signing and TestFlight metadata readiness have not been checked.

## Invariants

- The connected tmux Pi process remains the sole live JSONL writer.
- The broker stays loopback-only by default and is exposed only through authenticated Tailscale HTTPS/WSS.
- Secrets must not be logged, committed, placed in defaults, or included in screenshots/test artifacts.
