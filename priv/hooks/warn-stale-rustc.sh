#!/usr/bin/env bash
set -euo pipefail

MAX_AGE_DAYS=56

command -v rustc >/dev/null 2>&1 || exit 0
version="$(rustc -vV 2>/dev/null)" || exit 0

release="$(printf '%s\n' "$version" | sed -n 's/^release: //p')"
commit_date="$(printf '%s\n' "$version" | sed -n 's/^commit-date: //p')"

# Nightly and beta are rebuilt continuously; only a stable release can be stale.
case "$release" in
"" | *nightly* | *beta*) exit 0 ;;
esac
[ -n "$commit_date" ] || exit 0

# GNU date first, then BSD/macOS. Neither working is not worth a warning.
built="$(date -d "$commit_date" +%s 2>/dev/null \
    || date -j -f %Y-%m-%d "$commit_date" +%s 2>/dev/null)" || exit 0
age=$((($(date +%s) - built) / 86400))

if [ "$age" -gt "$MAX_AGE_DAYS" ]; then
    printf '\n  rustc %s was built %s, %s days ago.\n' "$release" "$commit_date" "$age"
    printf '  CI lints with the current stable, so clippy here can pass what CI rejects.\n'
    printf '  Update with `mise upgrade rust`, or `rustup update stable`.\n\n'
fi
