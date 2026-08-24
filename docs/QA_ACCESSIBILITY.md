# Simulator visual and accessibility QA

Validated on 2026-08-24 using the booted **Vipi iPhone, iOS 26.5** simulator and a locally signed Debug build.

## Matrix

| Variant | Visual capture | Accessibility-identifier XCUITest |
|---|---:|---:|
| Light appearance | Pass | Pass |
| Dark appearance | Pass | Pass |
| Increase Contrast | Pass | Pass |
| Dynamic Type: accessibility XXXL | Pass after responsive metric layout fix | Pass with scroll-to-control checks |
| Reduce Motion | Pass | Pass |
| Reduce Transparency | Pass | Pass |
| VoiceOver preference + AX hierarchy queries | Pass | Pass |

The reusable command is:

```bash
./scripts/run-accessibility-matrix.sh
```

It uses `simctl ui` for appearance, contrast, and content size; simulator accessibility preferences for Reduce Motion, Reduce Transparency, and VoiceOver; captures each variant; and runs `testPairingAndConnectionControlsAreAccessible` against every configuration. It restores normal dark/large settings afterward.

The first accessibility-XXXL run exposed horizontally compressed session metrics. `SessionListView` now switches metrics to a vertical layout for accessibility content sizes. The matrix was rerun after that fix and passed.

A labeled contact sheet is committed at [`preview/vipi-accessibility-matrix.png`](../preview/vipi-accessibility-matrix.png). XCUITests additionally traverse stable identifiers for pairing, host, token, connect, rotation, session rows, transcript, composer, send, compact, and abort controls.
