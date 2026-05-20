#!/usr/bin/env bash
#
# compute-next-version.sh — print the next Beaver version based on
# commit messages since the last git tag.
#
# Convention (D23):
#
#   release:    → MAJOR bump   (1.2.3 → 2.0.0)
#   feat:       → MINOR bump   (1.2.3 → 1.3.0)
#   (anything)  → PATCH bump   (1.2.3 → 1.2.4)
#
# Highest-impact prefix in the range wins (release > feat > patch).
#
# Usage:
#   ./scripts/compute-next-version.sh              # prints next version to stdout
#   ./scripts/compute-next-version.sh --verbose    # also prints diagnostic info to stderr
#
# Output:
#   Stdout = next version string only (e.g. "1.0.4"). Caller can do
#     $(./scripts/compute-next-version.sh) safely.
#   Stderr = diagnostic info under --verbose (last tag, commit count,
#     bump type, current version). Always present in CI logs but never
#     pollutes the value.
#
# Edge cases:
#   - No tags yet  → starts from the current pbxproj MARKETING_VERSION
#                    and applies one patch bump.
#   - pbxproj manually bumped past the last tag → respects the manual
#                    value (no further bump). Lets `make bump` / hot-fix
#                    paths override the automation.
#
set -euo pipefail

PBXPROJ="Beaver.xcodeproj/project.pbxproj"
VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1

log() { [ "$VERBOSE" -eq 1 ] && echo "$@" >&2; return 0; }

if [ ! -f "$PBXPROJ" ]; then
    echo "❌ Run this from the repo root (couldn't find $PBXPROJ)" >&2
    exit 1
fi

# ─── Read current MARKETING_VERSION from the pbxproj ──────────────────

CURRENT="$(grep -m1 'MARKETING_VERSION = ' "$PBXPROJ" \
    | sed 's/.*= //; s/;//' | tr -d '[:space:]')"

if ! echo "$CURRENT" | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$'; then
    echo "❌ MARKETING_VERSION '$CURRENT' isn't a valid semver" >&2
    exit 1
fi

# Normalize to X.Y.Z (pad missing .Z with .0).
case "$(echo "$CURRENT" | awk -F. '{print NF}')" in
    2) CURRENT="${CURRENT}.0" ;;
    3) ;;
    *) echo "❌ Unexpected version shape: $CURRENT" >&2; exit 1 ;;
esac

IFS='.' read -r MAJ MIN PAT <<< "$CURRENT"

# ─── Find the last release tag (X.Y.Z shape only) ─────────────────────

LAST_TAG="$(git tag --list --sort=-v:refname \
    | grep -E '^[0-9]+\.[0-9]+(\.[0-9]+)?$' \
    | head -1 || true)"

# ─── If the pbxproj was manually bumped past the last tag, respect it ─
#
# This covers the "I want to force a specific version locally and then
# push" workflow — make bump VERSION=2.0.0 leaves pbxproj at 2.0.0 while
# the last tag is still 1.x. CI should release 2.0.0, not 1.x.1.

if [ -n "$LAST_TAG" ] && [ "$LAST_TAG" != "$CURRENT" ]; then
    # Compare with version-sort to see if pbxproj > last tag.
    NEWER="$(printf '%s\n%s\n' "$LAST_TAG" "$CURRENT" | sort -V | tail -1)"
    if [ "$NEWER" = "$CURRENT" ]; then
        log "ℹ️  pbxproj at $CURRENT is ahead of last tag $LAST_TAG — respecting manual bump."
        echo "$CURRENT"
        exit 0
    fi
fi

# ─── Determine bump type from commits since the last tag ──────────────

if [ -z "$LAST_TAG" ]; then
    RANGE="HEAD"
    log "ℹ️  No tags yet — scanning all commits."
else
    RANGE="${LAST_TAG}..HEAD"
    log "ℹ️  Scanning commits in range $RANGE"
fi

COMMITS="$(git log --pretty=%s "$RANGE" 2>/dev/null || true)"
COMMIT_COUNT="$(echo "$COMMITS" | grep -c . || true)"
log "ℹ️  Found ${COMMIT_COUNT} commit(s)."

BUMP="patch"
if echo "$COMMITS" | grep -qE '^release(\(.*\))?:'; then
    BUMP="major"
elif echo "$COMMITS" | grep -qE '^feat(\(.*\))?:'; then
    BUMP="minor"
fi

log "ℹ️  Bump type: $BUMP"
log "ℹ️  Current version: $CURRENT"

# ─── Compute the next version ─────────────────────────────────────────

case "$BUMP" in
    major) NEW="$((MAJ + 1)).0.0" ;;
    minor) NEW="${MAJ}.$((MIN + 1)).0" ;;
    patch) NEW="${MAJ}.${MIN}.$((PAT + 1))" ;;
esac

log "ℹ️  Next version:    $NEW"

echo "$NEW"
