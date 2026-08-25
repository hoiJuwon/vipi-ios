# Personal-device readiness

Validated on 2026-08-24 from clean `main` on Xcode 26 / iOS 26.5 SDK.

Vipi is a private utility for the owner's devices. App Store Connect, TestFlight, public distribution, store review metadata, notarized distribution, and release marketing are intentionally out of scope.

## Passing validation

The canonical `npm test` command passes:

- TypeScript checking
- 9 host/real-extension integration tests
- 10 Swift tests
- 4 XCUITests with zero skips

A generic-device unsigned Release archive also succeeds and contains the arm64 app, app icon, privacy manifest, generated Info.plist, and Release metadata (`0.1.0` / `1`). The archive is retained only as a build-integrity check; uploading or distributing it is not required.

## Current physical-device blocker

No local Apple code-signing identity is installed:

```text
0 valid identities found
```

A device build therefore requires selecting an Apple ID or Personal Team in Xcode. This is required by iOS even for a private app installed only on the owner's phone; it is not a distribution requirement.

## Minimal personal installation

1. In Xcode **Settings → Accounts**, add the owner's Apple ID if it is not already present.
2. Keep the canonical bundle ID `com.abovetech.vipi.choijuwon` and use the existing Abovetech development team/profile so installation updates the existing app and preserves pairing data.
3. Connect and trust the owner's iPhone, select it as the run destination, and press **Run**.

No App Store Connect app record, TestFlight group, distribution certificate, archive upload, review submission, compliance questionnaire, screenshots, or public privacy page is needed. A free Personal Team can install the app but may require periodic rebuilding; a paid developer membership provides longer-lived provisioning.
