#!/usr/bin/env bash
#
# Dates CHANGELOG.md for a release (D90): moves everything under
# `## [Unreleased]` into `## [X.Y.Z] - YYYY-MM-DD` right below it, leaves
# `[Unreleased]` empty, and points the `[Unreleased]:` compare link at the
# new tag. An empty `[Unreleased]` gives "No user-facing changes."
#
# CI runs it in the release job so the change lands in the
# `version X.Y.Z [skip ci]` commit; `make bump` runs it too.
#
#   scripts/changelog-release.sh X.Y.Z [YYYY-MM-DD] [FILE]
#   scripts/changelog-release.sh --check     # self-test (make test)
#
# Idempotent: a file that already has `## [X.Y.Z]` is left alone. A file
# without `## [Unreleased]` only warns — the release must not fail over
# its notes.

set -euo pipefail

release() {
    local ver="$1" date="$2" file="$3"
    if ! echo "$ver" | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$'; then
        echo "❌ '$ver' isn't a version like 1.2.3" >&2
        return 1
    fi
    if ! grep -q '^## \[Unreleased\]' "$file"; then
        echo "⚠️  No '## [Unreleased]' in $file — left as is." >&2
        return 0
    fi
    if grep -qE "^## \[${ver//./\\.}\]" "$file"; then
        echo "ℹ️  $file already has [$ver] — left as is." >&2
        return 0
    fi
    local tmp
    tmp="$(mktemp)"
    awk -v ver="$ver" -v date="$date" '
        function flush(  i, first, last) {
            first = 1; last = n
            while (first <= n && lines[first] ~ /^[[:space:]]*$/) first++
            while (last >= first && lines[last] ~ /^[[:space:]]*$/) last--
            print "## [" ver "] - " date
            print ""
            if (first > last) print "No user-facing changes."
            for (i = first; i <= last; i++) print lines[i]
            print ""
            held = 0
        }
        /^## \[Unreleased\]/ { print; print ""; held = 1; next }
        held && /^## /       { flush() }
        held                 { lines[++n] = $0; next }
        /^\[Unreleased\]: /  { sub(/compare\/.*\.\.\.HEAD/, "compare/" ver "...HEAD") }
        { print }
        END { if (held) flush() }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
    echo "▸ CHANGELOG: [Unreleased] → [$ver] - $date" >&2
}

check() {
    # not local: the EXIT trap runs after check returns
    dir="$(mktemp -d)"
    trap 'rm -rf "$dir"' EXIT

    cat > "$dir/in.md" <<'EOF'
# Changelog

Intro.

## [Unreleased]

### Added
- New thing.

## [1.0.0] - 2026-01-01

### Fixed
- Old fix.

[Unreleased]: https://example.com/compare/1.0.0...HEAD
EOF
    cat > "$dir/want.md" <<'EOF'
# Changelog

Intro.

## [Unreleased]

## [1.1.0] - 2026-02-03

### Added
- New thing.

## [1.0.0] - 2026-01-01

### Fixed
- Old fix.

[Unreleased]: https://example.com/compare/1.1.0...HEAD
EOF
    release 1.1.0 2026-02-03 "$dir/in.md" 2>/dev/null
    diff -u "$dir/want.md" "$dir/in.md"

    # Running again for the same version changes nothing.
    release 1.1.0 2026-02-04 "$dir/in.md" 2>/dev/null
    diff -u "$dir/want.md" "$dir/in.md"

    # Nothing unreleased: the section says so.
    release 1.1.1 2026-02-05 "$dir/in.md" 2>/dev/null
    grep -A2 '^## \[1.1.1\] - 2026-02-05' "$dir/in.md" | grep -q '^No user-facing changes.$'

    # [Unreleased] as the last section (no older version, no links).
    printf '# C\n\n## [Unreleased]\n\n- Only.\n' > "$dir/last.md"
    release 0.1.0 2026-03-01 "$dir/last.md" 2>/dev/null
    printf '# C\n\n## [Unreleased]\n\n## [0.1.0] - 2026-03-01\n\n- Only.\n\n' | diff -u - "$dir/last.md"

    echo "✅ changelog-release.sh --check passed"
}

if [ "${1:-}" = "--check" ]; then
    check
else
    [ $# -ge 1 ] || { echo "Usage: $0 X.Y.Z [YYYY-MM-DD] [FILE] | --check" >&2; exit 1; }
    release "$1" "${2:-$(date -u +%F)}" "${3:-CHANGELOG.md}"
fi
