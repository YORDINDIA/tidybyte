#!/usr/bin/env bash
#
# Regenerates all macOS String Catalogs from Swift source and Info.plist keys:
#   - Sources/MacOSCleanerCore/Resources/Localizable.xcstrings
#   - Sources/MacOSCleanerAppKit/Resources/Localizable.xcstrings
#   - Configuration/InfoPlist.xcstrings
#
# Run from `macos/`:
#   ./scripts/localization/refresh.sh
#
# Pass `--strict` to fail if any key is still untranslated (`needs_review`),
# or `--prune` to drop catalog keys no longer referenced in Swift sources.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"

BUILD_ARGS=()
CHECK_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --prune) BUILD_ARGS+=("--prune") ;;
    --strict) CHECK_ARGS+=("--strict") ;;
    *) echo "Usage: $0 [--prune] [--strict]" >&2; exit 2 ;;
  esac
done

echo "==> Testing format placeholder handling"
node --test "$SCRIPT_DIR/format-placeholders.test.mjs"

echo "==> Extracting Swift & Info.plist strings"
node "$SCRIPT_DIR/extract.mjs" | tail -11

echo "==> Building String Catalogs (Core, AppKit, InfoPlist)"
node "$SCRIPT_DIR/build-catalog.mjs" ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}

echo "==> Validating catalogs"
node "$SCRIPT_DIR/check.mjs" ${CHECK_ARGS[@]+"${CHECK_ARGS[@]}"}

echo
echo "macOS localization catalogs refreshed."
