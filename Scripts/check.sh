#!/usr/bin/env bash
set -euo pipefail

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/macfsw-clang-cache}"

swift test --disable-sandbox
swift build --disable-sandbox
