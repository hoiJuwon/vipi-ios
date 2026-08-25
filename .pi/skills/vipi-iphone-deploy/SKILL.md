---
name: vipi-iphone-deploy
description: Deploys the current Vipi main branch to the owner's physical iPhone 15 Pro through the Tailscale-connected MacBook Pro. Use whenever applying, installing, launching, or validating Vipi on the physical iPhone.
---

# Deploy Vipi to the physical iPhone

Run the bundled deployment script from the repository root:

```bash
.pi/skills/vipi-iphone-deploy/scripts/deploy.sh
```

The script performs the complete workflow without creating a Pi or tmux session:

1. Verifies that local `main` is clean.
2. Transfers `main` to `/Users/choijuwon/vipi-ios` on `100.88.238.58` with a Git bundle. This avoids relying on the MacBook's headless GitHub Keychain access.
3. Fast-forwards the clean remote checkout.
4. Starts signed `xcodebuild` through the MacBook's logged-in Terminal GUI. A plain SSH build must not be used for signing because it can fail with `errSecInternalComponent`.
5. Installs the app on device `00008130-001C5C602883401C` with `devicectl`.
6. Terminates the previous app process if needed and launches `dev.vipi.ios`.
7. Waits for and verifies an explicit `success` status.

Deployment constants:

- MacBook SSH/Tailscale host: `100.88.238.58`
- MacBook repo: `/Users/choijuwon/vipi-ios`
- Device: iPhone 15 Pro `최주원`
- Xcode device UDID: `00008130-001C5C602883401C`
- Signing team: `Z8FZKW7QW6`
- Bundle ID: `dev.vipi.ios`

Only report deployment complete when the script reports `success`. On failure, inspect the printed remote build/deployment log and fix the issue rather than moving the deployment to the Mac Studio.
