# Implementation status

Updated 2026-08-24 after independent-audit remediation.

## Implemented

- The active tmux Pi process remains the sole JSONL writer.
- The real extension normalizes streaming messages, assistant tool calls, `toolResult` history entries, tool execution updates, history cursors, and runtime state.
- The broker provides bounded sequence replay, reconnect, correlated command responses, prompt/steer/follow-up/abort/compact routing, rate limits, loopback-only defaults, token rotation, and launchd setup.
- iOS reduces live/history/tool events, reconnects incrementally, stores pairing tokens in this-device-only Keychain, updates reconnect credentials on rotation, and surfaces transport/runtime command failures.
- Placeholder controls were removed. Production controls have actions and stable accessibility identifiers/semantics.
- Pairing QR output requires an explicit public HTTPS `.ts.net` URL; loopback is never encoded as the phone destination.

## Passing validation

- `npm run check`: TypeScript and all host/real-extension integration tests pass.
- Locally signed simulator Swift tests pass, including Keychain save/load/delete and pairing persistence with no skip.
- XCUITests pass demo and live broker/runtime flows.
- `scripts/run-accessibility-matrix.sh` validates true light/dark rendering, Increase Contrast, accessibility-XXXL Dynamic Type, Reduce Motion, Reduce Transparency, and VoiceOver semantics/navigation. See `docs/QA_ACCESSIBILITY.md`.
- Generic-device unsigned Release archive succeeds with the app icon and privacy manifest present.
- Secret scan is clean; `main` is clean and synchronized to the verified private origin.

## External release dependency

The exact remaining signing evidence and three required user actions are retained in [`RELEASE_EVIDENCE.md`](RELEASE_EVIDENCE.md). A signed archive currently stops at:

```text
Signing for "Vipi" requires a development team. Select a development team in the Signing & Capabilities editor.
```

No signing security was weakened.
