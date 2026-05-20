#!/usr/bin/env bash
set -euo pipefail

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/macfsw-clang-cache}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIGNING_CONFIG="$ROOT/Configuration/Signing.xcconfig"

read_xcconfig_value() {
  local key="$1"
  awk -F '=' -v requested="$key" '
    $1 ~ requested {
      value=$2
      gsub(/^[ \t]+|[ \t]+$/, "", value)
      print value
      exit
    }
  ' "$SIGNING_CONFIG"
}

for key in MARKETING_VERSION CURRENT_PROJECT_VERSION; do
  if [[ -z "$(read_xcconfig_value "$key")" ]]; then
    echo "$key must be set in Configuration/Signing.xcconfig." >&2
    exit 7
  fi
done

swift test --disable-sandbox
swift build --disable-sandbox
