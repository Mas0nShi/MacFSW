#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIGNING_CONFIG="$ROOT/Configuration/Signing.xcconfig"

usage() {
  cat <<'EOF'
Usage:
  Scripts/configure-github-signing-secrets.sh [options]

Options:
  --repo OWNER/REPO                         GitHub repository. Defaults to the current gh repository.
  --certificate-p12 PATH                    Existing Developer ID Application .p12 to upload.
  --export-login-keychain-p12 PATH          Export login keychain identities to this .p12, then upload it.
  --apple-id EMAIL                          Apple Account email for notarization. Prompts if omitted.
  --team-id TEAMID                          Apple Developer Team ID. Defaults to Configuration/Signing.xcconfig.
  --codesign-identity "Developer ID ..."    Optional signing identity variable.
  --skip-certificate                        Do not configure MACOS_CERTIFICATE_* secrets.
  --skip-notary                             Do not configure APPLE_ID or APPLE_APP_SPECIFIC_PASSWORD.
  -h, --help                                Show this help.

Examples:
  Scripts/configure-github-signing-secrets.sh \
    --certificate-p12 ~/Desktop/macfsw-developer-id.p12 \
    --apple-id you@example.com

  Scripts/configure-github-signing-secrets.sh \
    --export-login-keychain-p12 ~/Desktop/macfsw-developer-id.p12 \
    --apple-id you@example.com
EOF
}

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

read_secret() {
  local prompt="$1"
  local value

  printf '%s: ' "$prompt" >&2
  IFS= read -rs value
  printf '\n' >&2
  printf '%s' "$value"
}

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
}

base64_file() {
  local file_path="$1"

  base64 -i "$file_path" | tr -d '\n'
}

set_repo_secret() {
  local name="$1"
  local value="$2"

  printf '%s' "$value" | gh secret set "$name" --repo "$REPO" >/dev/null
  echo "Set GitHub secret: $name"
}

set_repo_variable() {
  local name="$1"
  local value="$2"

  printf '%s' "$value" | gh variable set "$name" --repo "$REPO" >/dev/null
  echo "Set GitHub variable: $name"
}

profile_matches() {
  local profile="$1"
  local bundle_id="$2"
  local required_entitlement="$3"

  strings "$profile" \
    | grep -Fq "<string>$TEAM_ID.$bundle_id</string>" \
    && strings "$profile" \
    | grep -Fq "<key>$required_entitlement</key>"
}

find_profile() {
  local bundle_id="$1"
  local required_entitlement="$2"
  local dir profile

  for dir in \
    "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" \
    "$HOME/Library/MobileDevice/Provisioning Profiles"; do
    [[ -d "$dir" ]] || continue

    while IFS= read -r -d '' profile; do
      if profile_matches "$profile" "$bundle_id" "$required_entitlement"; then
        printf '%s\n' "$profile"
        return 0
      fi
    done < <(find "$dir" -maxdepth 1 -type f \( -name "*.provisionprofile" -o -name "*.mobileprovision" \) -print0)
  done
}

first_developer_id_identity() {
  security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application:.*\)".*/\1/p' \
    | head -n 1
}

REPO=""
CERTIFICATE_P12=""
EXPORT_LOGIN_KEYCHAIN_P12=""
APPLE_ID=""
TEAM_ID="$(read_xcconfig_value DEVELOPMENT_TEAM)"
CODESIGN_IDENTITY=""
SKIP_CERTIFICATE=0
SKIP_NOTARY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO="${2:?Missing value for --repo}"
      shift 2
      ;;
    --certificate-p12)
      CERTIFICATE_P12="${2:?Missing value for --certificate-p12}"
      shift 2
      ;;
    --export-login-keychain-p12)
      EXPORT_LOGIN_KEYCHAIN_P12="${2:?Missing value for --export-login-keychain-p12}"
      shift 2
      ;;
    --apple-id)
      APPLE_ID="${2:?Missing value for --apple-id}"
      shift 2
      ;;
    --team-id)
      TEAM_ID="${2:?Missing value for --team-id}"
      shift 2
      ;;
    --codesign-identity)
      CODESIGN_IDENTITY="${2:?Missing value for --codesign-identity}"
      shift 2
      ;;
    --skip-certificate)
      SKIP_CERTIFICATE=1
      shift
      ;;
    --skip-notary)
      SKIP_NOTARY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -n "$CERTIFICATE_P12" && -n "$EXPORT_LOGIN_KEYCHAIN_P12" ]]; then
  echo "Use either --certificate-p12 or --export-login-keychain-p12, not both." >&2
  exit 1
fi

require_command gh
require_command security
require_command strings
require_command base64

if ! gh auth status >/dev/null 2>&1; then
  echo "gh is not authenticated. Run: gh auth login" >&2
  exit 1
fi

if [[ -z "$REPO" ]]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
fi

HOST_BUNDLE_ID="$(read_xcconfig_value MACFSW_HOST_BUNDLE_ID)"
EXTENSION_BUNDLE_ID="$(read_xcconfig_value MACFSW_EXTENSION_BUNDLE_ID)"

echo "Configuring GitHub Actions signing for: $REPO"
echo "Team ID: $TEAM_ID"
echo "Host bundle ID: $HOST_BUNDLE_ID"
echo "Extension bundle ID: $EXTENSION_BUNDLE_ID"

HOST_PROFILE="$(find_profile "$HOST_BUNDLE_ID" "com.apple.developer.system-extension.install")"
EXTENSION_PROFILE="$(find_profile "$EXTENSION_BUNDLE_ID" "com.apple.developer.endpoint-security.client")"

if [[ -z "$HOST_PROFILE" ]]; then
  echo "Could not find host provisioning profile for $HOST_BUNDLE_ID with system-extension.install." >&2
  exit 1
fi

if [[ -z "$EXTENSION_PROFILE" ]]; then
  echo "Could not find extension provisioning profile for $EXTENSION_BUNDLE_ID with endpoint-security.client." >&2
  exit 1
fi

set_repo_secret "MACFSW_HOST_PROVISIONPROFILE_BASE64" "$(base64_file "$HOST_PROFILE")"
set_repo_secret "MACFSW_EXTENSION_PROVISIONPROFILE_BASE64" "$(base64_file "$EXTENSION_PROFILE")"
set_repo_secret "APPLE_TEAM_ID" "$TEAM_ID"

if [[ "$SKIP_CERTIFICATE" != "1" ]]; then
  if [[ -n "$EXPORT_LOGIN_KEYCHAIN_P12" ]]; then
    DEVELOPER_ID_IDENTITY="$(first_developer_id_identity)"
    if [[ -z "$DEVELOPER_ID_IDENTITY" ]]; then
      cat >&2 <<'EOF'
No Developer ID Application identity is installed in the login keychain.
Install a Developer ID Application certificate first, or pass an existing .p12 with --certificate-p12.
EOF
      exit 1
    fi

    echo "Found Developer ID identity: $DEVELOPER_ID_IDENTITY"
    CERTIFICATE_PASSWORD="$(read_secret "New password for exported .p12")"
    if [[ -z "$CERTIFICATE_PASSWORD" ]]; then
      echo "The .p12 password cannot be empty." >&2
      exit 1
    fi

    mkdir -p "$(dirname "$EXPORT_LOGIN_KEYCHAIN_P12")"
    security export \
      -k "$HOME/Library/Keychains/login.keychain-db" \
      -t identities \
      -f pkcs12 \
      -P "$CERTIFICATE_PASSWORD" \
      -o "$EXPORT_LOGIN_KEYCHAIN_P12"

    CERTIFICATE_P12="$EXPORT_LOGIN_KEYCHAIN_P12"
  else
    if [[ -z "$CERTIFICATE_P12" ]]; then
      cat >&2 <<'EOF'
No certificate .p12 was provided.
Pass --certificate-p12 /path/to/developer-id.p12, or use --export-login-keychain-p12 /path/to/export.p12.
Use --skip-certificate to configure only profiles and notarization secrets.
EOF
      exit 1
    fi

    [[ -f "$CERTIFICATE_P12" ]] || {
      echo "Certificate file does not exist: $CERTIFICATE_P12" >&2
      exit 1
    }

    CERTIFICATE_PASSWORD="$(read_secret "Password for $CERTIFICATE_P12")"
    if [[ -z "$CERTIFICATE_PASSWORD" ]]; then
      echo "The .p12 password cannot be empty." >&2
      exit 1
    fi
  fi

  KEYCHAIN_PASSWORD="$(uuidgen | tr -d '-' )$(uuidgen | tr -d '-' )"
  set_repo_secret "MACOS_CERTIFICATE_P12_BASE64" "$(base64_file "$CERTIFICATE_P12")"
  set_repo_secret "MACOS_CERTIFICATE_PASSWORD" "$CERTIFICATE_PASSWORD"
  set_repo_secret "MACOS_KEYCHAIN_PASSWORD" "$KEYCHAIN_PASSWORD"
fi

if [[ "$SKIP_NOTARY" != "1" ]]; then
  if [[ -z "$APPLE_ID" ]]; then
    printf 'Apple Account email for notarization: ' >&2
    IFS= read -r APPLE_ID
  fi

  if [[ -z "$APPLE_ID" ]]; then
    echo "APPLE_ID cannot be empty." >&2
    exit 1
  fi

  APPLE_APP_SPECIFIC_PASSWORD="$(read_secret "Apple app-specific password")"
  if [[ -z "$APPLE_APP_SPECIFIC_PASSWORD" ]]; then
    echo "Apple app-specific password cannot be empty." >&2
    exit 1
  fi

  set_repo_secret "APPLE_ID" "$APPLE_ID"
  set_repo_secret "APPLE_APP_SPECIFIC_PASSWORD" "$APPLE_APP_SPECIFIC_PASSWORD"
fi

if [[ -z "$CODESIGN_IDENTITY" ]]; then
  CODESIGN_IDENTITY="$(first_developer_id_identity || true)"
fi

if [[ -n "$CODESIGN_IDENTITY" ]]; then
  set_repo_variable "MACOS_CODESIGN_IDENTITY" "$CODESIGN_IDENTITY"
else
  echo "No MACOS_CODESIGN_IDENTITY variable was set. The workflow will auto-detect the imported Developer ID identity."
fi

echo "Done."
