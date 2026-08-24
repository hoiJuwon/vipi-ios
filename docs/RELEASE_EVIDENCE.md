# Release evidence

Validated on 2026-08-24 from clean `main` on Xcode 26 / iOS 26.5 SDK.

## Passing unsigned archive

Reproducible command:

```bash
rm -rf /tmp/Vipi-final.xcarchive
xcodebuild \
  -project Vipi.xcodeproj \
  -scheme Vipi \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath /tmp/Vipi-final.xcarchive \
  CODE_SIGNING_ALLOWED=NO \
  archive
```

Result: `** ARCHIVE SUCCEEDED **`

Retained artifact assertions used after the archive:

```bash
test -f /tmp/Vipi-final.xcarchive/Products/Applications/Vipi.app/PrivacyInfo.xcprivacy
test -f /tmp/Vipi-final.xcarchive/Products/Applications/Vipi.app/AppIcon60x60@2x.png
```

Both pass. The archive includes the generated Info.plist, app icon, privacy manifest, arm64 device binary, and Release version/build metadata (`0.1.0` / `1`).

## Exact signing blocker

Signed archive command (the same command without `CODE_SIGNING_ALLOWED=NO`) fails only at provisioning with:

```text
Vipi.xcodeproj: error: Signing for "Vipi" requires a development team. Select a development team in the Signing & Capabilities editor. (in target 'Vipi' from project 'Vipi')
** ARCHIVE FAILED **
```

No development-team identifier, App Store Connect account, certificate, or provisioning profile is present in the repository. None was fabricated or security-weakened.

## Minimal user actions

1. In Xcode **Settings → Accounts**, add the Apple ID that has access to the intended App Store Connect team.
2. Open target **Vipi → Signing & Capabilities**, choose that team, and confirm `dev.vipi.ios` is an available App ID (change it to the registered private identifier if required).
3. Run **Product → Archive**, then **Distribute App → App Store Connect → Upload** and complete the normal TestFlight compliance prompts.

No source change should be needed unless the registered bundle identifier differs.
