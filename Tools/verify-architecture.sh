#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h}
cd "$repo_root"

for contract_source in Packages/Sources/StasisContracts/*.swift; do
  if rg -n '^import (AppKit|SwiftUI|IOKit|SMCKit|smc_power)$' "$contract_source"; then
    echo "StasisContracts must contain wire-safe Foundation types only."
    exit 1
  fi
done

for core_source in Packages/Sources/StasisCore/*.swift; do
  if rg -n '^import (AppKit|SwiftUI|IOKit|SMCKit|smc_power)$' "$core_source"; then
    echo "StasisCore must not depend on UI or hardware implementations."
    exit 1
  fi
done

for ui_source in Packages/Sources/StasisNativeUI/*.swift; do
  if rg -n '^import (IOKit|SMCKit|smc_power)$' "$ui_source"; then
    echo "StasisNativeUI must render presentation data without hardware access."
    exit 1
  fi
done

if rg -n '^import (stasis|StasisCore|StasisNativeUI)$' Examples --glob '*.swift'; then
  echo "Modules may depend on StasisContracts and StasisModuleSDK, not host internals."
  exit 1
fi

echo "Architecture dependency checks passed."
