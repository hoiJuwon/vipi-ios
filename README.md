# Vipi

A native SwiftUI chat client for Pi sessions that stay alive in tmux on your Mac. Vipi deliberately does **not** reproduce Vim or terminal UI on the phone: tmux is the runtime, the iPhone is a polished chat surface.

## Personal-device architecture

The repository contains all three layers needed for the product:

- `Vipi/` — iOS 18+ SwiftUI application with demo data and a typed WebSocket client
- `host/` — loopback-only Node/TypeScript broker, token auth, tmux registry discovery, and session routing
- `extension/` — Pi extension that registers each active process with the broker and forwards prompts/events

Implemented app surfaces:

- workspace-grouped live session list
- working, input-needed, completed, unread, and offline states
- streaming chat transcript
- prompt / queue / steer composer
- expandable tool execution cards
- model, thinking, and context status
- session details and conversation-branch sheets
- cross-session activity feed
- Tailscale host and device-token settings
- built-in demo mode for UI development without a running host

## Architecture

```text
SwiftUI app
    │ HTTPS / WSS
    ▼
Tailscale Serve
    │
127.0.0.1:8765 Vipi host
    ├── reads ~/.pi/agent/tmux-session-tree.json
    └── routes to connected Pi extensions
                    │
           active Pi processes in tmux
```

The JSONL session remains owned by the existing Pi process. The host never opens a second writer for a live terminal session.

## Build the iOS app

Requirements: Xcode 16+, XcodeGen, and an iOS 18+ simulator/device. Vipi is maintained for private use on the owner's devices; App Store Connect, TestFlight, review metadata, public distribution, and release marketing are out of scope.

```bash
brew install xcodegen
xcodegen generate
open Vipi.xcodeproj
```

Canonical validation (provisions the live host/runtime fixture, runs host checks, locally signed Swift/Keychain tests, and every XCUITest with zero skips):

```bash
npm test
```

For a compile-only check:

```bash
xcodebuild -project Vipi.xcodeproj \
  -scheme Vipi \
  -destination 'platform=iOS Simulator,name=Vipi iPhone' \
  CODE_SIGNING_ALLOWED=NO build
```

Production launches with no fabricated sessions. Open Settings to pair a host. Demo data is available only through the explicit **Use demo data** action (and the isolated UI-test launch seam).

The owner's existing physical-device installation uses the canonical bundle ID `com.abovetech.vipi.choijuwon`. Keep this identifier unchanged so deployment upgrades the existing app and preserves its pairing data. Use the repository's `vipi-iphone-deploy` skill/script for installation; App Store Connect, archive upload, and TestFlight are not required.

## Run the host

```bash
npm install
npm run host
```

The host:

- binds to `127.0.0.1:8765` by default
- creates a 256-bit token at `~/.pi/agent/vipi/token` with mode `0600` without logging it
- prints a pairing QR only when explicitly started with `VIPI_SHOW_PAIRING_QR=1`
- exposes `GET /health`
- accepts mobile and Pi-runtime WebSocket clients at `/ws`

Environment overrides:

```bash
VIPI_HOST=127.0.0.1 VIPI_PORT=8765 npm run host
```

## Tailscale

Keep the host on loopback and publish it through Tailscale Serve:

```bash
tailscale serve --bg http://127.0.0.1:8765
```

Use `https://<machine>.<tailnet>.ts.net` in Vipi Settings and copy the token from:

```bash
cat ~/.pi/agent/vipi/token
```

Do not bind this service publicly. The host refuses non-loopback binds unless the explicit unsafe override `VIPI_ALLOW_NON_LOOPBACK=1` is set. A connected device can ask Pi to execute commands and modify files with your account permissions.

Verify that Serve is tailnet-only before pairing:

```bash
tailscale serve status
tailscale status
```

For QR pairing, first use the HTTPS `.ts.net` URL shown by `tailscale serve status`, stop any unattended terminal recording, then run:

```bash
VIPI_PUBLIC_URL=https://mac-studio.your-tailnet.ts.net \
VIPI_SHOW_PAIRING_QR=1 npm run host
```

The host refuses to emit a QR without a public HTTPS `.ts.net` URL and never encodes its loopback listener as the phone destination. The QR is a bearer secret. Token rotation is available to an authenticated app and atomically replaces the token, revoking other mobile connections.

## Run at login with launchd

After reviewing the generated service settings:

```bash
./scripts/install-launchd.sh
# later, if needed:
./scripts/uninstall-launchd.sh
```

The LaunchAgent binds only to `127.0.0.1`, restarts on failure, and stores logs under `~/.pi/agent/vipi/`. Token values are never written to those logs.

## Load the Pi extension during development

Start the host first, then run Pi with the extension:

```bash
pi -e /absolute/path/to/vipi-ios/extension/index.ts
```

Or install the repository as a local Pi package after reviewing it:

```bash
pi install /absolute/path/to/vipi-ios
```

The extension does not start a public listener. It connects outbound to `ws://127.0.0.1:8765/ws` and authenticates with the same local token.

## Protocol v1

Client commands currently wired:

- `auth.authenticate`
- `sessions.list`
- `session.prompt` (`prompt`, `steer`, `followUp`)
- `session.abort`
- `session.history`

Runtime events currently forwarded:

- session registration and state snapshots
- message streaming and completion
- tool start, update, and end
- settled/completed status

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for ownership and roadmap details.

## License

MIT
