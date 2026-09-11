#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

build_beta() {
  local label="$1"
  local build_number="$2"

  STASIS_MARKETING_VERSION="0.2.4" \
  STASIS_BUILD_NUMBER="$build_number" \
  STASIS_RELEASE_LABEL="$label" \
    "$ROOT_DIR/Packaging/build_universal_installer.sh"
}

build_beta "beta.1" "401"
build_beta "beta.2" "402"
build_beta "beta.3" "403"
build_beta "beta.4" "404"
build_beta "beta.5" "405"
build_beta "beta.6" "406"
build_beta "beta.7" "407"
build_beta "beta.8" "408"
build_beta "beta.9" "409"
build_beta "beta.10" "410"
