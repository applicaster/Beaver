#!/usr/bin/env bash
#
# sign-appcast.sh — sign a release zip with Sparkle's Ed25519 key
# and append a fresh <item> to docs/appcast.xml.
#
# Called from scripts/release.sh after the notarized zip is produced.
# Also runnable standalone:
#
#     ./scripts/sign-appcast.sh 1.1.0 build/Beaver-1.1.0.zip
#
# Private key source — pick whichever is set:
#
#   SPARKLE_PRIVATE_KEY_BASE64   Base-64 string from `generate_keys -x`.
#                                Used in CI. Takes precedence.
#   (otherwise)                  Reads from the macOS login keychain
#                                (where `generate_keys` stored it).
#
set -euo pipefail

if [ $# -ne 2 ]; then
    echo "Usage: $0 <version> <path-to-zip>" >&2
    echo "Example: $0 1.1.0 build/Beaver-1.1.0.zip" >&2
    exit 2
fi

VERSION="$1"
ZIP_PATH="$2"
APPCAST_PATH="${APPCAST_PATH:-docs/appcast.xml}"
DOWNLOAD_URL_BASE="${DOWNLOAD_URL_BASE:-https://github.com/applicaster/Beaver/releases/download}"

if [ ! -f "$ZIP_PATH" ]; then
    echo "❌ Zip not found: $ZIP_PATH" >&2; exit 1
fi
if [ ! -f "$APPCAST_PATH" ]; then
    echo "❌ Appcast not found: $APPCAST_PATH" >&2; exit 1
fi

# ─── Locate sign_update ───────────────────────────────────────────────
#
# Sparkle ships `sign_update` inside its SPM artifact bundle. After
# `xcodebuild -resolvePackageDependencies` the binary lives under
# DerivedData. If we can't find it there (clean checkout, or running
# this script outside Xcode's context), download Sparkle's official
# release tarball — small, fast, deterministic.

find_local_sign_update() {
    find ~/Library/Developer/Xcode/DerivedData \
        -path '*Sparkle*' -name 'sign_update' -type f \
        2>/dev/null | head -1
}

SIGN_UPDATE="$(find_local_sign_update)"
if [ -z "$SIGN_UPDATE" ] || [ ! -x "$SIGN_UPDATE" ]; then
    SPARKLE_VERSION="${SPARKLE_VERSION:-2.6.4}"
    TMPDIR_SPARKLE="$(mktemp -d)"
    trap "rm -rf '$TMPDIR_SPARKLE'" EXIT
    echo "▸ Fetching Sparkle ${SPARKLE_VERSION} (for sign_update)…"
    curl -fsSL \
        "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz" \
        | tar xJf - -C "$TMPDIR_SPARKLE"
    SIGN_UPDATE="${TMPDIR_SPARKLE}/bin/sign_update"
fi

if [ ! -x "$SIGN_UPDATE" ]; then
    echo "❌ Could not locate or download sign_update" >&2
    exit 1
fi

# ─── Sign the zip ─────────────────────────────────────────────────────
#
# sign_update outputs ONE LINE shaped like:
#   sparkle:edSignature="abc…" length="6373894"
# We embed that verbatim into the <enclosure> attribute list.

echo "▸ Signing $(basename "$ZIP_PATH")… (using $SIGN_UPDATE)"
SIGN_STDERR=$(mktemp)
KEY_FILE=""
cleanup() {
    rm -f "$SIGN_STDERR"
    [ -n "$KEY_FILE" ] && [ -f "$KEY_FILE" ] && rm -f "$KEY_FILE"
}
trap cleanup EXIT

# Modern sign_update doesn't take the private key as a command-line
# string. It reads either from `-f <file>` or, by default, from the
# macOS login keychain. So in the CI path we decode the env var back
# into a temp file and pass it via -f.
if [ -n "${SPARKLE_PRIVATE_KEY_BASE64:-}" ]; then
    KEY_FILE="$(mktemp)"
    chmod 600 "$KEY_FILE"
    # Strip any whitespace/newlines that pbcopy or CircleCI's text
    # field might have added before decoding — base64 -d on macOS
    # tolerates it, but Linux's variant is stricter.
    printf '%s' "$SPARKLE_PRIVATE_KEY_BASE64" \
        | tr -d '[:space:]' \
        | base64 --decode > "$KEY_FILE"
    KEY_BYTES="$(wc -c <"$KEY_FILE" | tr -d '[:space:]')"
    echo "   key source: SPARKLE_PRIVATE_KEY_BASE64 → ${KEY_FILE} (${KEY_BYTES} bytes)"
    SIG_LINE="$("$SIGN_UPDATE" -f "$KEY_FILE" "$ZIP_PATH" 2>"$SIGN_STDERR" || true)"
else
    echo "   key source: macOS login keychain"
    SIG_LINE="$("$SIGN_UPDATE" "$ZIP_PATH" 2>"$SIGN_STDERR" || true)"
fi

if [ -z "$SIG_LINE" ] || ! echo "$SIG_LINE" | grep -q "edSignature"; then
    echo "❌ sign_update failed." >&2
    echo "   stdout: ${SIG_LINE:-<empty>}" >&2
    echo "   stderr: $(cat "$SIGN_STDERR")" >&2
    echo "   tool:   $SIGN_UPDATE" >&2
    "$SIGN_UPDATE" --help 2>&1 | head -30 >&2 || true
    exit 1
fi
echo "   signature: $SIG_LINE"

# ─── Gather metadata for the <item> block ─────────────────────────────

PUBDATE="$(LC_TIME=C date -u "+%a, %d %b %Y %H:%M:%S +0000")"
PBXPROJ="Beaver.xcodeproj/project.pbxproj"

BUILD="$(grep -m1 'CURRENT_PROJECT_VERSION = ' "$PBXPROJ" \
    | sed 's/.*= //; s/;//' | tr -d '[:space:]')"

MIN_SYSTEM="$(grep -m1 'MACOSX_DEPLOYMENT_TARGET = ' "$PBXPROJ" \
    | sed 's/.*= //; s/;//' | tr -d '[:space:]')"

DOWNLOAD_URL="${DOWNLOAD_URL_BASE}/${VERSION}/Beaver-${VERSION}.zip"

# ─── Bail out if this version is already in the appcast ───────────────

if grep -q "<sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>" "$APPCAST_PATH"; then
    echo "ℹ️  Appcast already contains an entry for ${VERSION}. Skipping."
    exit 0
fi

# ─── Build the new <item> and insert it ───────────────────────────────
#
# Splice in directly after `<language>en</language>` so newest entries
# bubble to the top of the channel. Sparkle reads top-to-bottom
# regardless, but this matches the convention in the seed file's
# placeholder comment.

NEW_ITEM=$(cat <<EOF
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${PUBDATE}</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MIN_SYSTEM}</sparkle:minimumSystemVersion>
      <enclosure
        url="${DOWNLOAD_URL}"
        ${SIG_LINE}
        type="application/octet-stream" />
    </item>
EOF
)

# Find the line number of <language>en</language>, then write
# {head, new_item, tail} back to the file.
LANG_LINE="$(grep -n "<language>en</language>" "$APPCAST_PATH" | head -1 | cut -d: -f1)"
if [ -z "$LANG_LINE" ]; then
    echo "❌ Appcast missing <language>en</language> anchor — refusing to mutate" >&2
    exit 1
fi

TMP_APPCAST="$(mktemp)"
{
    head -n "$LANG_LINE" "$APPCAST_PATH"
    echo
    echo "$NEW_ITEM"
    tail -n +$((LANG_LINE + 1)) "$APPCAST_PATH"
} > "$TMP_APPCAST"
mv "$TMP_APPCAST" "$APPCAST_PATH"

echo "✅ Appended Beaver ${VERSION} to ${APPCAST_PATH}"
echo "   ${SIG_LINE}"
