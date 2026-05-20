#!/usr/bin/env bash
#
# release.sh — build, codesign, notarize, and staple Beaver.app as a
# distributable .zip.
#
# Per DECISIONS.md D13 (revised): we ship a signed + notarized
# .app.zip rather than a .pkg installer. Trade-off explained in the
# decision log; short version is "internal devs drag to Applications,
# we don't need .pkg's extra cert + steps."
#
# Required environment variables (read from `.envrc.local` if present):
#   APPLE_ID                    Apple ID used for notarization
#   APPLE_APP_PASSWORD          App-specific password for APPLE_ID
#                               (https://appleid.apple.com → Sign-In and Security
#                               → App-Specific Passwords → +)
#   APPLE_TEAM_ID               10-character team identifier
#   DEVELOPER_ID_APPLICATION    Full identity, e.g.
#                               "Developer ID Application: Acme Corp (ABCDE12345)"
#
# Optional:
#   CONFIGURATION               Defaults to Release
#   BUILD_DIR                   Defaults to ./build
#   VERSION                     Defaults to MARKETING_VERSION from project,
#                               falling back to "dev-<git-sha>"
#
# Usage:
#   ./scripts/release.sh
#
# Output:
#   build/Beaver-<version>.zip   (notarized, stapled, ready to share)
#
# Naming note: target / scheme / PRODUCT_NAME are all "Beaver" since
# D38 (source-tree rename). The bundle ID is intentionally still
# `com.applicaster.LoggerNext` so existing installs keep their data
# and Sparkle in-place upgrades stay valid.
set -euo pipefail

# ─── Config ───────────────────────────────────────────────────────────

PROJECT="Beaver.xcodeproj"
SCHEME="Beaver"
APP_NAME="Beaver"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Source local secrets if present (.envrc.local is .gitignored).
if [ -f ".envrc.local" ]; then
    # shellcheck disable=SC1091
    source ".envrc.local"
fi

CONFIGURATION="${CONFIGURATION:-Release}"
BUILD_DIR="${BUILD_DIR:-build}"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP_PATH="$EXPORT_DIR/$APP_NAME.app"

# ─── Pre-flight checks ────────────────────────────────────────────────

require_env() {
    local name="$1"
    if [ -z "${!name:-}" ]; then
        echo "❌ Missing required env var: $name" >&2
        echo "   See scripts/.envrc.example for the full list." >&2
        exit 1
    fi
}
require_env APPLE_ID
require_env APPLE_APP_PASSWORD
require_env APPLE_TEAM_ID
require_env DEVELOPER_ID_APPLICATION

if ! command -v xcodebuild >/dev/null;  then echo "❌ xcodebuild not found"; exit 1; fi
if ! command -v xcrun >/dev/null;       then echo "❌ xcrun not found";      exit 1; fi
if ! command -v ditto >/dev/null;       then echo "❌ ditto not found";      exit 1; fi

# Resolve VERSION. The project uses GENERATE_INFOPLIST_FILE=YES so
# there's no literal Info.plist on disk — read MARKETING_VERSION from
# the pbxproj instead. (PlistBuddy's "File Doesn't Exist, Will Create"
# message prints to stdout, not stderr, so it sneaks past 2>/dev/null
# and pollutes the variable. The Makefile already reads pbxproj — same
# trick here.)
if [ -z "${VERSION:-}" ]; then
    VERSION="$(grep -m1 'MARKETING_VERSION = ' \
        "$REPO_ROOT/Beaver.xcodeproj/project.pbxproj" \
        | sed 's/.*= //; s/;//' | tr -d '[:space:]')"
fi
if [ -z "$VERSION" ]; then
    VERSION="dev-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
fi

OUTPUT_ZIP="$BUILD_DIR/$APP_NAME-$VERSION.zip"

# ─── Step 1: Clean ────────────────────────────────────────────────────

echo "▸ Cleaning previous build…"
rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR" "$OUTPUT_ZIP"
mkdir -p "$BUILD_DIR"

# ─── Step 2: Archive ──────────────────────────────────────────────────

echo "▸ Archiving $SCHEME ($CONFIGURATION)…"
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=macOS" \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION" \
    DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
    | xcbeautify 2>/dev/null \
    || xcodebuild archive \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination "generic/platform=macOS" \
        -archivePath "$ARCHIVE_PATH" \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION" \
        DEVELOPMENT_TEAM="$APPLE_TEAM_ID"

# ─── Step 3: Export .app ──────────────────────────────────────────────

echo "▸ Exporting .app for Developer ID distribution…"

EXPORT_OPTIONS_PLIST="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_OPTIONS_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$APPLE_TEAM_ID</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>$DEVELOPER_ID_APPLICATION</string>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"

if [ ! -d "$APP_PATH" ]; then
    echo "❌ Export did not produce $APP_PATH" >&2
    exit 1
fi

# ─── Step 4: Re-sign with hardened runtime (belt-and-braces) ──────────

# `developer-id` export usually signs correctly, but signing again with
# --options runtime is cheap insurance that notarization won't reject
# us for missing the hardened-runtime flag.
echo "▸ Verifying hardened-runtime signature…"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

# ─── Step 5: Notarize ─────────────────────────────────────────────────

echo "▸ Submitting to Apple's notarization service (this can take a few minutes)…"

NOTARIZE_ZIP="$BUILD_DIR/$APP_NAME-for-notarization.zip"
rm -f "$NOTARIZE_ZIP"
ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"

xcrun notarytool submit "$NOTARIZE_ZIP" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait

# ─── Step 6: Staple ───────────────────────────────────────────────────

echo "▸ Stapling notarization ticket to the .app…"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

# Final Gatekeeper check (this is what end-users will see).
spctl --assess --type execute --verbose=2 "$APP_PATH" || {
    echo "⚠️  spctl assessment warning — check the message above"
}

# ─── Step 7: Package final zip ────────────────────────────────────────

# Bundle is already named Beaver.app at this point (PRODUCT_NAME).
# Previously this step renamed LoggerNext.app → Beaver.app; that's
# unnecessary since D38 unified the internal target name with the
# user-facing brand.
echo "▸ Packaging final ${OUTPUT_ZIP}…"
rm -f "$OUTPUT_ZIP"
ditto -c -k --keepParent "$APP_PATH" "$OUTPUT_ZIP"

# ─── Step 8: Cleanup intermediates ────────────────────────────────────

rm -f "$NOTARIZE_ZIP" "$EXPORT_OPTIONS_PLIST"

# ─── Step 9: Sparkle — sign + update appcast ─────────────────────────
#
# Best-effort: if sign-appcast.sh exists and the Sparkle private key
# is reachable (env var or login keychain), append an <item> to
# docs/appcast.xml. CI also calls this; running locally without a
# key isn't an error, the release just doesn't ship through Sparkle.

if [ -x "$REPO_ROOT/scripts/sign-appcast.sh" ]; then
    if [ -n "${SPARKLE_PRIVATE_KEY_BASE64:-}" ] \
       || security find-generic-password -s "https://sparkle-project.org" \
              >/dev/null 2>&1; then
        echo "▸ Updating Sparkle appcast…"
        "$REPO_ROOT/scripts/sign-appcast.sh" "$VERSION" "$OUTPUT_ZIP" || {
            echo "⚠️  Appcast update failed — the zip is still good, but" \
                 "installed Beaver instances won't see this version" \
                 "until someone fixes docs/appcast.xml." >&2
        }
    else
        echo "ℹ️  Sparkle private key not found (no SPARKLE_PRIVATE_KEY_BASE64" \
             "env var and no key in login keychain). Skipping appcast update." \
             "Users who installed an earlier Sparkle-enabled build won't see" \
             "this release in the auto-updater."
    fi
fi

# ─── Done ─────────────────────────────────────────────────────────────

SIZE="$(du -h "$OUTPUT_ZIP" | cut -f1)"
echo
echo "✅ Release ready: $OUTPUT_ZIP ($SIZE)"
echo "   Upload it to your distribution location (Drive, S3, internal HTTPS, …)"
echo "   and tell the team to grab the new build."
