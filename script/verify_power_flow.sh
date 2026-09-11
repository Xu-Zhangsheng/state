#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_BINARY="$ROOT_DIR/.build/power-flow-layout-tests"

mkdir -p "$ROOT_DIR/.build"
xcrun swiftc \
  "$ROOT_DIR/Stasis/Views/PowerFlowLayout.swift" \
  "$ROOT_DIR/Tests/PowerFlowLayout/main.swift" \
  -o "$TEST_BINARY"
"$TEST_BINARY"
