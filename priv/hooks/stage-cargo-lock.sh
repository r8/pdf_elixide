#!/usr/bin/env bash
set -euo pipefail

if ! git diff --quiet -- Cargo.lock 2>/dev/null; then
    git add Cargo.lock
fi
