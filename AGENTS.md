# Vipi project instructions

## Deployment topology

- The source/host machine is the Mac Studio (`mac-studio`, Tailscale `100.92.223.17`).
- The physical test device is **not attached to the Mac Studio**. Never use the Mac Studio's `devicectl` result to conclude that no iPhone is available.
- The physical iPhone 15 Pro is attached to the MacBook Pro over USB/developer services.
- MacBook deployment host: `100.88.238.58` over Tailscale SSH; hostname `MacBook-Pro-52.local`; user `choijuwon`.
- Remote repository: `/Users/choijuwon/vipi-ios`.
- Physical iPhone name: `최주원`; Xcode destination/device UDID: `00008130-001C5C602883401C`; CoreDevice identifier: `7BE48DBD-8776-5394-981D-B6CAC5A5AD0B`.
- Personal signing uses team `Z8FZKW7QW6` and the existing Xcode-managed wildcard development profile on the MacBook.
- This app is private/personal. Do not add TestFlight, App Store Connect, review, or public-distribution work unless explicitly requested.

## Required physical-device workflow

- For any request to “apply to iPhone”, “install on iPhone”, or verify a physical-device change, load and follow `.pi/skills/vipi-iphone-deploy/SKILL.md`.
- Sync the verified local `main` to the MacBook repository, build there, install with `devicectl`, and launch `dev.vipi.ios`.
- Codesigning from a plain SSH process can fail with `errSecInternalComponent` because it lacks GUI Keychain authorization. Run the signed `xcodebuild` through the logged-in MacBook Terminal GUI as documented by the deployment skill.
- Do not ask the user to connect the iPhone to the Mac Studio; it is already connected to the MacBook Pro.
- Report success only after build, install, and launch each succeed.

## Agent workflow

- Perform work directly in the current Pi session. Do not create a new Pi session, Goal session, subagent session, or tmux work session.
- Run relevant tests, review the diff, commit small passing changes, and push private `main`.
