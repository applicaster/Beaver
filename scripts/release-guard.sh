#!/usr/bin/env bash
#
# Only the newest commit on main releases (D93). Each merge to main starts
# a release job; when merges come quickly, an older job finds main has
# moved on and steps aside. The newer job releases everything since the
# last tag (D23, D90).
#
#   scripts/release-guard.sh start REMOTE   # before the build
#   scripts/release-guard.sh push REMOTE    # push HEAD (the version commit) to main
#   scripts/release-guard.sh --check        # self-test (make test)
#
# Exit 0: go on. `start` first fast-forwards HEAD over CI's own
# `[skip ci]` commits (a previous release's version/appcast commits), so
# the build and the push start from main's tip. `push` pushed.
# Exit 3: main has a newer commit that runs its own release — stop
# cleanly and publish nothing. Nothing is tagged before `push` succeeds.
# Any other exit is a real failure (auth, network, branch protection).

set -euo pipefail

SKIP=3

# Commits on main that HEAD lacks and that start their own pipeline.
newer() {
    git log --format='  %h %s' --invert-grep -i -E \
        --grep='\[(skip ci|ci skip)\]' "HEAD..FETCH_HEAD"
}

skip() {
    echo "⏭  main has moved on past $(git rev-parse --short HEAD):" >&2
    echo "$1" >&2
    echo "   The newest commit's pipeline releases everything since the" \
         "last tag (D93). Nothing released here." >&2
    exit "$SKIP"
}

start() {
    git fetch --quiet "$1" main
    local tip n
    tip="$(git rev-parse FETCH_HEAD)"
    if ! git merge-base --is-ancestor HEAD "$tip"; then
        echo "❌ HEAD isn't in main's history — was main rewritten?" >&2
        exit 1
    fi
    n="$(newer)"
    [ -z "$n" ] || skip "$n"
    if [ "$(git rev-parse HEAD)" != "$tip" ]; then
        echo "▸ Fast-forwarding over CI's own commits:" >&2
        git log --format='  %h %s' "HEAD..$tip" >&2
        git merge --ff-only --quiet "$tip"
    fi
    echo "✅ $(git rev-parse --short HEAD) is main's tip — releasing." >&2
}

push() {
    if git push "$1" HEAD:main; then return 0; fi
    # Rejected. Skip only when main moved on to a commit that releases
    # itself; anything else is a real error and must fail.
    git fetch --quiet "$1" main
    local n
    n="$(newer)"
    [ -z "$n" ] || skip "$n"
    echo "❌ Push to main failed and main has no newer commit to release" \
         "instead. If only [skip ci] commits are new, another release job" \
         "ran at the same time — re-run this workflow." >&2
    exit 1
}

check() {
    # not local: the EXIT trap runs after check returns
    dir="$(mktemp -d)"
    trap 'rm -rf "$dir"' EXIT
    local o="$dir/origin.git" rc
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1   # no signing or hooks from ~/.gitconfig
    git init --quiet --bare -b main "$o"
    git clone --quiet "$o" "$dir/dev" 2>/dev/null
    merge() {
        git -C "$dir/dev" pull --quiet --ff-only 2>/dev/null || true   # empty repo at first
        git -C "$dir/dev" commit --quiet --allow-empty -m "$1"
        git -C "$dir/dev" push --quiet origin main
    }
    runner() { rm -rf "$dir/$1"; git clone --quiet "$o" "$dir/$1"; }
    guard() { (cd "$dir/$1" && "$self" "$2" "$o") 2>/dev/null; }
    bump() { git -C "$dir/$1" commit --quiet --allow-empty -m "version $2 [skip ci]"; }

    merge "feat: one"; runner a

    # Newest commit: go; nothing new to push is fine.
    guard a start
    guard a push

    # A second merge lands: the first job skips at start…
    merge "fix: two"; runner b
    rc=0; guard a start || rc=$?; [ "$rc" -eq "$SKIP" ]

    # …and the second job releases, pushing its version commit.
    guard b start; bump b 1.1.0; guard b push
    [ "$(git -C "$o" log -1 --format=%s main)" = "version 1.1.0 [skip ci]" ]

    # A job behind only CI's own [skip ci] commits fast-forwards and goes.
    merge "fix: three"; runner c
    bump dev 1.1.1; git -C "$dir/dev" push --quiet origin main
    guard c start
    [ "$(git -C "$dir/c" rev-parse HEAD)" = "$(git -C "$o" rev-parse main)" ]

    # Race: a merge lands between start and push — push skips, main keeps
    # the merge, and nothing was tagged.
    merge "fix: four"
    bump c 1.1.2
    rc=0; guard c push || rc=$?; [ "$rc" -eq "$SKIP" ]
    [ "$(git -C "$o" log -1 --format=%s main)" = "fix: four" ]

    # A rejected push with main unmoved (branch protection, auth) fails.
    runner d; guard d start; bump d 1.1.2
    printf '#!/bin/sh\necho denied >&2; exit 1\n' > "$o/hooks/pre-receive"
    chmod +x "$o/hooks/pre-receive"
    rc=0; guard d push || rc=$?; [ "$rc" -eq 1 ]
    rm "$o/hooks/pre-receive"

    # An unreachable remote fails too.
    rc=0; (cd "$dir/d" && "$self" start "$dir/missing.git") 2>/dev/null || rc=$?
    [ "$rc" -ne 0 ] && [ "$rc" -ne "$SKIP" ]

    echo "✅ release-guard.sh --check passed"
}

self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
case "${1:-}" in
    --check) check ;;
    start|push) [ $# -eq 2 ] || { echo "Usage: $0 start|push REMOTE | --check" >&2; exit 1; }
                "$1" "$2" ;;
    *) echo "Usage: $0 start|push REMOTE | --check" >&2; exit 1 ;;
esac
