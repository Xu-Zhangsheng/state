#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT_DIR/Design/PowerFlowBeta}"
TOOL_BINARY="$ROOT_DIR/.build/power-flow-snapshot-tool"

mkdir -p "$ROOT_DIR/.build" "$OUTPUT_DIR"
xcrun swiftc \
  -parse-as-library \
  "$ROOT_DIR/Stasis/Models/PowerSource.swift" \
  "$ROOT_DIR/Stasis/Models/BatteryMetrics.swift" \
  "$ROOT_DIR/Stasis/Support/PowerFormatter.swift" \
  "$ROOT_DIR/Stasis/Views/MenuStyle.swift" \
  "$ROOT_DIR/Stasis/Views/MenuViews.swift" \
  "$ROOT_DIR/Stasis/Views/PowerFlowLayout.swift" \
  "$ROOT_DIR/Stasis/Views/PowerSankeyView.swift" \
  "$ROOT_DIR/Tests/PowerFlowSnapshot/main.swift" \
  -o "$TOOL_BINARY"
"$TOOL_BINARY" "$OUTPUT_DIR"
