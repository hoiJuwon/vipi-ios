---
name: vipi-iphone-deploy
description: Deploys Vipi to the owner's currently connected physical iPhone, checking the Mac Studio first and falling back to the Tailscale-connected MacBook Pro. Use whenever applying, installing, launching, or validating Vipi on the physical iPhone.
---

# Deploy Vipi to the physical iPhone

Run from the repository root:

```bash
.pi/skills/vipi-iphone-deploy/scripts/deploy.sh
```

The script performs the entire workflow without creating a Pi or tmux session:

1. Verifies clean local `main`.
2. Checks the Mac Studio for a connected physical iPhone first.
3. If none is connected locally, checks MacBook Pro `100.88.238.58` and syncs `main` there with a Git bundle.
4. Builds through the selected Mac's logged-in Terminal GUI so the signing Keychain is available.
5. Refuses to install unless the built bundle ID is exactly `com.abovetech.vipi.choijuwon`.
6. Installs over the existing canonical app so its data container and pairing state are preserved.
7. Removes only the known accidental duplicate bundle `dev.vipi.ios` after the canonical installation succeeds.
8. Launches `com.abovetech.vipi.choijuwon` and verifies that exactly one canonical Vipi app remains.
9. Checks the Mac Studio host health and requires a connected mobile client plus live sessions/runtimes, catching lost pairing or an empty session list.

Constants:

- Canonical bundle: `com.abovetech.vipi.choijuwon`
- Accidental duplicate to remove: `dev.vipi.ios`
- Normal MacBook SSH host: `100.88.238.58`
- MacBook repository: `/Users/choijuwon/vipi-ios`
- iPhone: iPhone 15 Pro `최주원`
- Normal MacBook Xcode device UDID: `00008130-001C5C602883401C`
- Signing team: `Z8FZKW7QW6`

Never infer that the device is unavailable only because the Mac Studio has none connected. Conversely, do not always force MacBook deployment: the owner may connect the iPhone to the Mac Studio at home.

Only report completion when build, canonical bundle verification, install/update, duplicate removal, launch, final installed-app verification, and live host/session connectivity all succeed.
