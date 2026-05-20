#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-debug}"
CONFIG_DIR="$ROOT/Configuration"
SIGNING_CONFIG="$CONFIG_DIR/Signing.xcconfig"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/.build/bundles}"
APP_NAME="MacFSW"
APP_EXECUTABLE="MacFSWApp"
EXT_EXECUTABLE="MacFSWEndpointExtension"
APP_ICON="$ROOT/Sources/MacFSWApp/Resources/MacFSW-AppIcon.icns"
PROVISIONING_PROFILE_DIR="${PROVISIONING_PROFILE_DIR:-$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles}"

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

DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-$(read_xcconfig_value DEVELOPMENT_TEAM)}"
MARKETING_VERSION="${MARKETING_VERSION:-$(read_xcconfig_value MARKETING_VERSION)}"
BUILD_VERSION="${CURRENT_PROJECT_VERSION:-$(read_xcconfig_value CURRENT_PROJECT_VERSION)}"
HOST_BUNDLE_ID="${MACFSW_HOST_BUNDLE_ID:-$(read_xcconfig_value MACFSW_HOST_BUNDLE_ID)}"
EXTENSION_BUNDLE_ID="${MACFSW_EXTENSION_BUNDLE_ID:-$(read_xcconfig_value MACFSW_EXTENSION_BUNDLE_ID)}"
XPC_SERVICE_NAME="${MACFSW_XPC_SERVICE_NAME:-$(read_xcconfig_value MACFSW_XPC_SERVICE_NAME)}"
CODE_SIGN="${CODE_SIGN:-1}"
CODE_SIGN_IDENTITY_PATTERN="${CODE_SIGN_IDENTITY_PATTERN:-Apple Development}"
CODE_SIGN_TIMESTAMP="${CODE_SIGN_TIMESTAMP:-none}"

if [[ "$CODE_SIGN_TIMESTAMP" == "1" || "$CODE_SIGN_TIMESTAMP" == "true" || "$CODE_SIGN_TIMESTAMP" == "yes" ]]; then
  CODE_SIGN_TIMESTAMP_ARGS=(--timestamp)
elif [[ "$CODE_SIGN_TIMESTAMP" == "0" || "$CODE_SIGN_TIMESTAMP" == "false" || "$CODE_SIGN_TIMESTAMP" == "no" || "$CODE_SIGN_TIMESTAMP" == "none" ]]; then
  CODE_SIGN_TIMESTAMP_ARGS=(--timestamp=none)
else
  CODE_SIGN_TIMESTAMP_ARGS=(--timestamp="$CODE_SIGN_TIMESTAMP")
fi

if [[ -z "$XPC_SERVICE_NAME" ]]; then
  XPC_SERVICE_NAME="$DEVELOPMENT_TEAM.$EXTENSION_BUNDLE_ID.xpc"
fi

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/macfsw-clang-cache}"

swift build --disable-sandbox --configuration "$CONFIGURATION" --product "$APP_EXECUTABLE"
swift build --disable-sandbox --configuration "$CONFIGURATION" --product "$EXT_EXECUTABLE"
BIN_DIR="$(swift build --disable-sandbox --configuration "$CONFIGURATION" --show-bin-path 2>/dev/null)"

APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
EXT_BUNDLE="$APP_BUNDLE/Contents/Library/SystemExtensions/$EXTENSION_BUNDLE_ID.systemextension"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Library/SystemExtensions"
mkdir -p "$EXT_BUNDLE/Contents/MacOS"

cp "$BIN_DIR/$APP_EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/$APP_EXECUTABLE"
cp "$BIN_DIR/$EXT_EXECUTABLE" "$EXT_BUNDLE/Contents/MacOS/$EXT_EXECUTABLE"
cp "$APP_ICON" "$APP_BUNDLE/Contents/Resources/MacFSW-AppIcon.icns"

render_template() {
  local source="$1"
  local destination="$2"
  sed \
    -e 's|$(MARKETING_VERSION)|'"$MARKETING_VERSION"'|g' \
    -e 's|$(CURRENT_PROJECT_VERSION)|'"$BUILD_VERSION"'|g' \
    -e 's|$(MACFSW_HOST_BUNDLE_ID)|'"$HOST_BUNDLE_ID"'|g' \
    -e 's|$(MACFSW_EXTENSION_BUNDLE_ID)|'"$EXTENSION_BUNDLE_ID"'|g' \
    -e 's|$(MACFSW_XPC_SERVICE_NAME)|'"$XPC_SERVICE_NAME"'|g' \
    "$source" > "$destination"
}

render_template "$CONFIG_DIR/MacFSWApp-Info.plist" "$APP_BUNDLE/Contents/Info.plist"
render_template "$CONFIG_DIR/MacFSWSystemExtension-Info.plist" "$EXT_BUNDLE/Contents/Info.plist"

profile_matches() {
  local profile="$1"
  local bundle_id="$2"
  local required_entitlement="$3"

  strings "$profile" \
    | grep -Fq "<string>$DEVELOPMENT_TEAM.$bundle_id</string>" \
    && strings "$profile" \
    | grep -Fq "<key>$required_entitlement</key>"
}

find_provisioning_profile() {
  local bundle_id="$1"
  local required_entitlement="$2"
  local profile

  [[ -d "$PROVISIONING_PROFILE_DIR" ]] || return 0

  while IFS= read -r -d '' profile; do
    if profile_matches "$profile" "$bundle_id" "$required_entitlement"; then
      printf '%s\n' "$profile"
      return 0
    fi
  done < <(find "$PROVISIONING_PROFILE_DIR" -maxdepth 1 -type f \( -name "*.provisionprofile" -o -name "*.mobileprovision" \) -print0)
}

HOST_PROVISIONING_PROFILE="${MACFSW_HOST_PROVISIONING_PROFILE:-$(find_provisioning_profile "$HOST_BUNDLE_ID" "com.apple.developer.system-extension.install")}"
EXTENSION_PROVISIONING_PROFILE="${MACFSW_EXTENSION_PROVISIONING_PROFILE:-$(find_provisioning_profile "$EXTENSION_BUNDLE_ID" "com.apple.developer.endpoint-security.client")}"

if [[ -n "$HOST_PROVISIONING_PROFILE" ]]; then
  cp "$HOST_PROVISIONING_PROFILE" "$APP_BUNDLE/Contents/embedded.provisionprofile"
fi

if [[ -n "$EXTENSION_PROVISIONING_PROFILE" ]]; then
  cp "$EXTENSION_PROVISIONING_PROFILE" "$EXT_BUNDLE/Contents/embedded.provisionprofile"
fi

certificate_matches_team() {
  local identity_hash="$1"
  local common_name="$2"

  security find-certificate -a -Z -c "$common_name" 2>/dev/null \
    | awk -v identity_hash="$identity_hash" -v team="$DEVELOPMENT_TEAM" '
      /^SHA-1 hash:/ {
        in_matching_cert = ($3 == identity_hash)
        next
      }
      in_matching_cert && index($0, "\"subj\"<blob>=") && index($0, team) {
        found = 1
      }
      END {
        exit(found ? 0 : 1)
      }
    '
}

find_identity() {
  local line identity_hash identity_name

  while IFS= read -r line; do
    [[ "$line" == *"$CODE_SIGN_IDENTITY_PATTERN"* ]] || continue

    identity_hash="$(printf '%s\n' "$line" | awk '{print $2}')"
    identity_name="$(printf '%s\n' "$line" | sed -n 's/.*"\(.*\)".*/\1/p')"
    [[ -n "$identity_hash" && -n "$identity_name" ]] || continue

    if certificate_matches_team "$identity_hash" "$identity_name"; then
      printf '%s\n' "$identity_hash"
      return 0
    fi
  done < <(security find-identity -v -p codesigning 2>/dev/null)
}

if [[ "$CODE_SIGN" == "1" ]]; then
  IDENTITY="${CODE_SIGN_IDENTITY:-$(find_identity)}"
  if [[ -z "$IDENTITY" ]]; then
    cat >&2 <<EOF
No $CODE_SIGN_IDENTITY_PATTERN signing identity for team $DEVELOPMENT_TEAM was found.

Set CODE_SIGN_IDENTITY to a signing identity hash/name, or run with CODE_SIGN=0
to build an unsigned .app bundle for structure inspection only.

System Extension activation requires a signed .app with:
- com.apple.developer.system-extension.install on the host app
- com.apple.developer.endpoint-security.client on the system extension
- valid provisioning profiles for restricted entitlements

Available code signing identities:
$(security find-identity -v -p codesigning 2>/dev/null || true)
EOF
    exit 2
  fi

  if [[ -z "$HOST_PROVISIONING_PROFILE" || -z "$EXTENSION_PROVISIONING_PROFILE" ]]; then
    cat >&2 <<EOF
Missing provisioning profile for restricted System Extension entitlements.

Expected matching profiles:
- $HOST_BUNDLE_ID with com.apple.developer.system-extension.install
- $EXTENSION_BUNDLE_ID with com.apple.developer.endpoint-security.client

Searched:
$PROVISIONING_PROFILE_DIR

Set MACFSW_HOST_PROVISIONING_PROFILE and MACFSW_EXTENSION_PROVISIONING_PROFILE
if Xcode stores them elsewhere.
EOF
    exit 4
  fi

  codesign --force "${CODE_SIGN_TIMESTAMP_ARGS[@]}" --options runtime --generate-entitlement-der \
    --entitlements "$CONFIG_DIR/MacFSWSystemExtension.entitlements" \
    --sign "$IDENTITY" \
    "$EXT_BUNDLE"

  codesign --force "${CODE_SIGN_TIMESTAMP_ARGS[@]}" --options runtime --generate-entitlement-der \
    --entitlements "$CONFIG_DIR/MacFSWApp.entitlements" \
    --sign "$IDENTITY" \
    "$APP_BUNDLE"

  verify_entitlement() {
    local bundle="$1"
    local key="$2"
    if ! codesign -d --entitlements :- "$bundle" 2>/dev/null | grep -q "<key>$key</key>"; then
      echo "Signed bundle is missing required entitlement: $key" >&2
      echo "Bundle: $bundle" >&2
      exit 3
    fi
  }

  verify_entitlement "$APP_BUNDLE" "com.apple.developer.system-extension.install"
  verify_entitlement "$EXT_BUNDLE" "com.apple.developer.endpoint-security.client"

  if ! /usr/libexec/PlistBuddy -c "Print :NSSystemExtensionUsageDescription" "$APP_BUNDLE/Contents/Info.plist" >/dev/null 2>&1; then
    echo "Host app Info.plist is missing NSSystemExtensionUsageDescription." >&2
    exit 5
  fi

  if ! /usr/libexec/PlistBuddy -c "Print :NSEndpointSecurityMachServiceName" "$EXT_BUNDLE/Contents/Info.plist" >/dev/null 2>&1; then
    echo "System Extension Info.plist is missing NSEndpointSecurityMachServiceName." >&2
    exit 5
  fi

  HOST_XPC_VALUE="$(/usr/libexec/PlistBuddy -c "Print :MacFSWXPCServiceName" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
  EXT_XPC_VALUE="$(/usr/libexec/PlistBuddy -c "Print :NSEndpointSecurityMachServiceName" "$EXT_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
  if [[ -z "$HOST_XPC_VALUE" || "$HOST_XPC_VALUE" != "$EXT_XPC_VALUE" ]]; then
    echo "Host app and System Extension XPC service names do not match." >&2
    echo "Host: $HOST_XPC_VALUE" >&2
    echo "Extension: $EXT_XPC_VALUE" >&2
    exit 6
  fi

  codesign --verify --strict --deep "$APP_BUNDLE"
fi

echo "$APP_BUNDLE"
