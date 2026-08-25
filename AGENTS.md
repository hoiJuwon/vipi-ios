# Vipi project instructions

## Deployment topology

- The source/host machine is the Mac Studio (`mac-studio`, Tailscale `100.92.223.17`).
- First check the current Mac Studio with `xcrun devicectl list devices`; the owner may attach the iPhone there when working at home.
- If no connected physical iPhone is present on the Mac Studio, check the MacBook Pro over Tailscale SSH. The iPhone is normally attached there over USB/developer services.
- MacBook deployment host: `100.88.238.58` over Tailscale SSH; hostname `MacBook-Pro-52.local`; user `choijuwon`.
- Remote repository: `/Users/choijuwon/vipi-ios`.
- Physical iPhone name: `최주원`; Xcode destination/device UDID: `00008130-001C5C602883401C`; CoreDevice identifier: `7BE48DBD-8776-5394-981D-B6CAC5A5AD0B`.
- Physical-device signing uses team `Z8FZKW7QW6` and the existing Xcode-managed wildcard development profile.
- Canonical physical app bundle ID: `com.abovetech.vipi.choijuwon`. Never deploy another bundle ID; changing it installs a duplicate app and loses access to the existing app container/pairing state.
- This app is private/personal. Do not add TestFlight, App Store Connect, review, or public-distribution work unless explicitly requested.

## Required physical-device workflow

- For any request to “apply to iPhone”, “install on iPhone”, or verify a physical-device change, load and follow `.pi/skills/vipi-iphone-deploy/SKILL.md`.
- Deploy locally when a connected iPhone is found on the Mac Studio. Otherwise sync verified local `main` to the MacBook repository and deploy there.
- Codesigning from a plain SSH process can fail with `errSecInternalComponent` because it lacks GUI Keychain authorization. For MacBook deployment, run signed `xcodebuild` through its logged-in Terminal GUI as documented by the deployment skill.
- Before installation, verify the built app's bundle ID is exactly `com.abovetech.vipi.choijuwon`.
- After installation, verify that the canonical app exists, remove only the known accidental duplicate `dev.vipi.ios`, launch the canonical app, and confirm there is exactly one Vipi installation.
- Report success only after build, identity verification, install/update, duplicate cleanup, launch, and installed-app verification succeed.

## Agent workflow

- Perform work directly in the current Pi session. Do not create a new Pi session, Goal session, subagent session, or tmux work session.
- Run relevant tests, review the diff, commit small passing changes, and push private `main`.
