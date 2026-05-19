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

## Install (end users)

**One-click install URL** — always the newest signed + notarized build:

> **https://applicaster.github.io/Beaver/**

Or skip the landing page and go straight to the download:

> **https://github.com/applicaster/Beaver/releases/latest/download/Beaver.zip**

1. Click the link. You'll get `Beaver.zip` (universal binary, signed
   + notarized by Apple — Gatekeeper accepts it on first launch).
2. Unzip → drag `Beaver.app` into `/Applications`.
3. Launch it. The toolbar's **Copy IP** button gives you the
   `<your-mac-ip>:9080` address to point your mobile SDK at.

From the second launch onward, Sparkle picks up new releases
automatically. You can also pick a specific version from
[the releases page](https://github.com/applicaster/Beaver/releases)
if you ever need to pin one.

## Release (publishing a new version)

There are two paths: **automated via CircleCI** (preferred — every
merge to `main` that bumps the version produces a signed release),
and **manual from your Mac** (fallback when CI is unavailable).

### Automated (CircleCI on merge to main)

`.circleci/config.yml` runs the full release pipeline on every push
to `main`. CI decides the next version from the commit messages
since the last tag (Conventional Commits–style), bumps the pbxproj,
builds, signs, notarizes, tags, publishes, and updates the Sparkle
appcast. **No local version bump needed.**

**Commit-message convention (D23):**

| Prefix on any commit since last tag | Bump | 1.0.3 becomes |
|---|---|---|
| `release:`         | major | 2.0.0 |
| `feat:`            | minor | 1.1.0 |
| (anything else, e.g. `fix:`, `chore:`) | patch | 1.0.4 |

Highest-impact prefix in the range wins. A PR with one `feat:` and
three `fix:` commits → minor bump.

**Per-release workflow:**

```bash
# 1. Make your changes. Commit with the right prefix.
git commit -m "feat: saved filter presets"
# or:  fix: typo in level menu
# or:  release: drop macOS 14 support

# 2. (Optional) Add a CHANGELOG note under [Unreleased].
#    CI extracts this as the GitHub Release body if present.

# 3. Push.
git push
```

CircleCI does the rest in ~5-7 min. The release appears at
`https://github.com/applicaster/Beaver/releases/latest`, and the
Sparkle appcast picks it up so installed Beaver instances see the
update on their next launch.

**Required CircleCI environment variables** (set once under Project
Settings → Environment Variables): `APPLE_ID`, `APPLE_APP_PASSWORD`,
`APPLE_TEAM_ID`, `DEVELOPER_ID_APPLICATION`, `DEVELOPER_ID_P12_BASE64`,
`DEVELOPER_ID_P12_PASSWORD`, `GITHUB_TOKEN`. See the comments at the
top of `.circleci/config.yml` for how to derive each value.

### Manual (from your Mac)

Use this when CI is down, you need to test a release locally, or
you're cutting a one-off build that shouldn't go through `main`.

**One-time setup**

```bash
cp scripts/.envrc.example .envrc.local
$EDITOR .envrc.local          # fill in the four secrets below
chmod +x scripts/release.sh   # if you cloned and the bit was stripped
```

`.envrc.local` is gitignored — your secrets stay local.

**What you need to provide in `.envrc.local`:**

| Env var                     | Where to get it                                      |
|-----------------------------|------------------------------------------------------|
| `APPLE_ID`                  | The Apple ID on the Developer Program account.       |
| `APPLE_APP_PASSWORD`        | App-specific password generated at https://appleid.apple.com → Sign-In and Security → App-Specific Passwords. |
| `APPLE_TEAM_ID`             | 10-char team ID from https://developer.apple.com/account → Membership Details. |
| `DEVELOPER_ID_APPLICATION`  | Exact certificate name from `security find-identity -v -p codesigning` (the one starting with "Developer ID Application:"). |

No installer profile is needed — D13 ships a notarized `.app.zip`,
not a `.pkg`. The Developer ID Application certificate is the only
signing identity required.

**Cutting a release manually**

```bash
# 1. Edit CHANGELOG.md — move [Unreleased] items under a new section.
$EDITOR CHANGELOG.md

# 2. Bump + build + sign + notarize + zip in one command.
make ship VERSION=1.1.0       # ≈ 3–5 min including notarization
# → build/Beaver-1.1.0.zip

# 3. Push the commit + tag so CI sees consistent state.
git push && git push --tags

# 4. Publish the GitHub Release with the zip attached.
gh release create 1.1.0 build/Beaver-1.1.0.zip \
    --title "Beaver 1.1.0" \
    --notes-file CHANGELOG.md
```

`make ship` is `make bump VERSION=X.Y.Z` (bumps `MARKETING_VERSION` +
`CURRENT_PROJECT_VERSION`, commits, tags) followed by `make release`
(builds, signs, notarizes, zips). Each step can also be run on its
own — see below.

**Useful sub-commands**

```bash
make version                  # print current MARKETING_VERSION + build
make bump VERSION=1.1.0       # bump + commit + tag, no build
make release                  # build + notarize the current version
make tag                      # tag HEAD at the current MARKETING_VERSION
make build                    # plain Debug build, no signing
make test                     # run the unit tests
make clean                    # wipe build/ + DerivedData
```

**Troubleshooting**

| Symptom | Fix |
|---|---|
| `make: ./scripts/release.sh: Permission denied` | `chmod +x scripts/release.sh` |
| `No signing certificate "Developer ID Application" found` | Verify `DEVELOPER_ID_APPLICATION` in `.envrc.local` matches `security find-identity -v -p codesigning` output exactly |
| `notarytool 401 Unauthorized` | App-specific password is wrong or expired. Regenerate at appleid.apple.com |
| Notarization stuck on "in progress" | `xcrun notarytool log <submission-id> --apple-id … --password … --team-id …` to see the rejection reason |
| `spctl assess` warning at the end | Re-run `make release` — stapling didn't complete cleanly |
| `make ship` fails because tree is dirty | Commit/stash your changes first; `make bump` refuses to run on a dirty tree to avoid mixing version bumps with other edits |

## License

Same as the original `Logger` repository.
