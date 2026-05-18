# Beaver

Successor to the macOS `Logger` desktop app. Receives log events and
storage snapshots from a mobile client SDK over WebSocket, persists them
to SQLite, and renders a virtualized live feed plus a storages inspector.

> **Internal name.** The Xcode target, bundle identifier
> (`com.applicaster.LoggerNext`), entitlements file, and on-disk
> Application Support directory still use the codename `LoggerNext`.
> "Beaver" is the user-facing display name (CFBundleDisplayName,
> window title). Renaming the internals would orphan existing users'
> databases and force a new signing identity — not worth it for a
> rebrand. See DECISIONS.md D21.

## Status

Scaffolding in progress. The architecture and feature set are locked
(see `DECISIONS.md`); the working source tree is being built up under
`LoggerNext/`.

## Documents

| File                | Purpose                                                       |
|---------------------|---------------------------------------------------------------|
| `DECISIONS.md`      | Numbered, dated decision log (D1–D20). Source of truth.       |
| `ARCHITECTURE.md`   | Layered design synthesizing the decisions.                    |
| `PROTOCOL.md`       | Wire-protocol contract with the mobile SDK.                   |
| `COMMAND_CATALOG.md`| Forward-looking spec for the SDK `cmdspec` command (D17).     |
| `SCAFFOLD.md`       | One-time Xcode project setup steps.                           |

## Quick start

```bash
# After SCAFFOLD.md is followed:
open LoggerNext.xcodeproj
# ⌘R to build and run.
```

The app starts a WebSocket listener on `ws://<your-ip>:9080`. Use
**App ▸ Copy WebSocket URL** (⇧⌘C) to copy the address, then point your
mobile client at it.

## Requirements

- macOS 26 (Tahoe) or later
- Xcode 17 or later
- Swift 6 toolchain

## Release (deploy a signed + notarized build)

`scripts/release.sh` builds, codesigns, notarizes via `notarytool`,
staples the ticket, and packages a `.app.zip` ready to share.
`make ship` does this end-to-end including the version bump.

### One-time setup

```bash
cp scripts/.envrc.example .envrc.local
$EDITOR .envrc.local          # fill in the four secrets below
```

### Cutting a release

```bash
# Move items from [Unreleased] into a new section in CHANGELOG.md, then:
make ship VERSION=1.1.0       # ≈ 3–5 min including notarization
git push && git push --tags
# → build/Beaver-1.1.0.zip
```

`make ship` is `make bump VERSION=X.Y.Z` (bumps `MARKETING_VERSION` +
`CURRENT_PROJECT_VERSION`, commits, tags) followed by `make release`
(builds, signs, notarizes, zips). Each step can also be run on its own.

### Useful commands

```bash
make version                  # print current MARKETING_VERSION + build
make bump VERSION=1.1.0       # bump + commit + tag, no build
make release                  # build + notarize the current version
make tag                      # tag HEAD at the current MARKETING_VERSION
```

**What you need to provide in `.envrc.local`:**

| Env var                     | Where to get it                                      |
|-----------------------------|------------------------------------------------------|
| `APPLE_ID`                  | The Apple ID on the Developer Program account.       |
| `APPLE_APP_PASSWORD`        | App-specific password generated at https://appleid.apple.com → Sign-In and Security → App-Specific Passwords. |
| `APPLE_TEAM_ID`             | 10-char team ID from https://developer.apple.com/account → Membership Details. |
| `DEVELOPER_ID_APPLICATION`  | Exact certificate name from `security find-identity -v -p codesigning` (the one starting with "Developer ID Application:"). |

No installer profile is needed — D13 ships a notarized `.app.zip`, not
a `.pkg`. The Developer ID Application certificate is the only signing
identity required.

## License

Same as the original `Logger` repository.
