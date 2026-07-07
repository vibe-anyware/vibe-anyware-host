#!/usr/bin/env bash
set -euo pipefail

LABEL="app.vibeanyware.host"
DEFAULT_PORT="45731"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build/HostRelease"
INSTALL_DIR="${VIBE_ANYWARE_HOST_INSTALL_DIR:-${HOME}/Applications/VibeAnyware.app}"
PLIST_PATH="${HOME}/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="${HOME}/Library/Logs"

PORT="${VIBE_ANYWARE_PORT:-${DEFAULT_PORT}}"
LAN_COMMAND_KEY="${VIBE_ANYWARE_LAN_COMMAND_KEY:-}"
RELAY_ENDPOINT="${VIBE_ANYWARE_RELAY_ENDPOINT:-}"
RELAY_SERVER_ID="${VIBE_ANYWARE_RELAY_SERVER_ID:-}"
RELAY_ACCESS_TOKEN="${VIBE_ANYWARE_RELAY_ACCESS_TOKEN:-}"
RELAY_COMMAND_KEY="${VIBE_ANYWARE_RELAY_COMMAND_KEY:-}"
OFFICIAL_RELAY_SETUP_KEY="${VIBE_ANYWARE_OFFICIAL_RELAY_SETUP_KEY:-}"
CODESIGN_IDENTITY="${VIBE_ANYWARE_CODESIGN_IDENTITY:-}"

usage() {
  cat <<'EOF'
Usage:
  Scripts/install-macos-host.sh [options]

Options:
  --port <port>                         LAN listen port. Defaults to 45731.
  --lan-command-key <key>               Shared key for encrypted LAN command frames.
  --relay <endpoint>                    Relay endpoint, for example wss://relay.example.com.
  --server-id <id>                      Relay server ID for this Mac.
  --relay-access-token <token>          Relay access token.
  --relay-command-key <key>             Relay command encryption key.
  --official-relay-setup-key <key>      Official relay setup key from the iOS app.
  --install-dir <path>                  App bundle path. Defaults to ~/Applications/VibeAnyware.app.
  --codesign-identity <identity>        Code signing identity. Defaults to the first valid local identity.
  -h, --help                            Show this help.

The script builds the single VibeAnyware.app used for LAN, Custom Relay,
and Official Relay. It installs one user LaunchAgent, starts it, and prints the
LAN IP to enter in the iOS app for local fallback testing.
EOF
}

die() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

require_value() {
  local option="$1"
  local value="${2:-}"
  [[ -n "${value}" ]] || die "${option} requires a value."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      require_value "$1" "${2:-}"
      PORT="$2"
      shift 2
      ;;
    --lan-command-key)
      require_value "$1" "${2:-}"
      LAN_COMMAND_KEY="$2"
      shift 2
      ;;
    --relay)
      require_value "$1" "${2:-}"
      RELAY_ENDPOINT="$2"
      shift 2
      ;;
    --server-id)
      require_value "$1" "${2:-}"
      RELAY_SERVER_ID="$2"
      shift 2
      ;;
    --relay-access-token)
      require_value "$1" "${2:-}"
      RELAY_ACCESS_TOKEN="$2"
      shift 2
      ;;
    --relay-command-key)
      require_value "$1" "${2:-}"
      RELAY_COMMAND_KEY="$2"
      shift 2
      ;;
    --official-relay-setup-key)
      require_value "$1" "${2:-}"
      OFFICIAL_RELAY_SETUP_KEY="$2"
      shift 2
      ;;
    --install-dir)
      require_value "$1" "${2:-}"
      INSTALL_DIR="$2"
      shift 2
      ;;
    --codesign-identity)
      require_value "$1" "${2:-}"
      CODESIGN_IDENTITY="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        PORT="$1"
        shift
      else
        die "Unknown option: $1"
      fi
      ;;
  esac
done

[[ "${PORT}" =~ ^[0-9]+$ ]] || die "Port must be numeric."
if (( PORT < 1 || PORT > 65535 )); then
  die "Port must be between 1 and 65535."
fi

if [[ -n "${RELAY_ENDPOINT}" && -z "${RELAY_SERVER_ID}" ]]; then
  die "--server-id is required when --relay is provided."
fi
if [[ -z "${RELAY_ENDPOINT}" && -n "${RELAY_SERVER_ID}" ]]; then
  die "--relay is required when --server-id is provided."
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  die "xcodebuild is not installed. Install Xcode or Xcode Command Line Tools first."
fi

cd "${ROOT_DIR}"
if [[ ! -d "VibeAnyware.xcodeproj" ]]; then
  if command -v xcodegen >/dev/null 2>&1; then
    xcodegen generate
  else
    die "VibeAnyware.xcodeproj is missing and xcodegen is not installed."
  fi
fi

printf 'Building VibeAnyware Release...\n'
xcodebuild \
  -project VibeAnyware.xcodeproj \
  -scheme VibeAnyware \
  -configuration Release \
  -derivedDataPath "${BUILD_DIR}" \
  build >/dev/null

BINARY_PATH="${BUILD_DIR}/Build/Products/Release/VibeAnyware"
[[ -x "${BINARY_PATH}" ]] || die "Built host binary was not found at ${BINARY_PATH}."

APP_DIR="${INSTALL_DIR%/}"
if [[ "${APP_DIR}" != *.app ]]; then
  APP_DIR="${APP_DIR}.app"
fi
APP_CONTENTS_DIR="${APP_DIR}/Contents"
APP_MACOS_DIR="${APP_CONTENTS_DIR}/MacOS"
APP_RESOURCES_DIR="${APP_CONTENTS_DIR}/Resources"
HOST_BINARY="${APP_MACOS_DIR}/VibeAnyware"
# Prefer the macOS-styled icon (rounded rect + margins per Apple's icon
# grid); fall back to the square iOS artwork.
SOURCE_ICON="${ROOT_DIR}/Scripts/VibeAnyware-icon-1024.png"
if [[ ! -f "${SOURCE_ICON}" ]]; then
  SOURCE_ICON="${ROOT_DIR}/Scripts/VibeAnyware-icon-1024.png"
fi
APP_ICON_NAME="VibeAnyware"
APP_ICON_FILE="${APP_RESOURCES_DIR}/${APP_ICON_NAME}.icns"
MENU_ICON_FILE="${APP_RESOURCES_DIR}/VibeAnywareMenuIcon.png"

mkdir -p "${APP_MACOS_DIR}" "${APP_RESOURCES_DIR}" "${HOME}/Library/LaunchAgents" "${LOG_DIR}"
install -m 755 "${BINARY_PATH}" "${HOST_BINARY}"

if [[ -f "${SOURCE_ICON}" ]]; then
  tmp_iconset="$(mktemp -d "${TMPDIR:-/tmp}/VibeAnyware.iconset.XXXXXX")"
  iconset_dir="${tmp_iconset}/VibeAnyware.iconset"
  mkdir -p "${iconset_dir}"
  sips -z 16 16 "${SOURCE_ICON}" --out "${iconset_dir}/icon_16x16.png" >/dev/null
  sips -z 32 32 "${SOURCE_ICON}" --out "${iconset_dir}/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "${SOURCE_ICON}" --out "${iconset_dir}/icon_32x32.png" >/dev/null
  sips -z 64 64 "${SOURCE_ICON}" --out "${iconset_dir}/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "${SOURCE_ICON}" --out "${iconset_dir}/icon_128x128.png" >/dev/null
  sips -z 256 256 "${SOURCE_ICON}" --out "${iconset_dir}/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "${SOURCE_ICON}" --out "${iconset_dir}/icon_256x256.png" >/dev/null
  sips -z 512 512 "${SOURCE_ICON}" --out "${iconset_dir}/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "${SOURCE_ICON}" --out "${iconset_dir}/icon_512x512.png" >/dev/null
  cp "${SOURCE_ICON}" "${iconset_dir}/icon_512x512@2x.png"
  iconutil -c icns "${iconset_dir}" -o "${APP_ICON_FILE}"
  rm -rf "${tmp_iconset}"
  sips -z 64 64 "${SOURCE_ICON}" --out "${MENU_ICON_FILE}" >/dev/null
fi

# Monochrome template icon for the menu bar status item.
TEMPLATE_ICON="${ROOT_DIR}/Scripts/VibeAnyware-menuicon-template.png"
if [[ -f "${TEMPLATE_ICON}" ]]; then
  cp "${TEMPLATE_ICON}" "${APP_RESOURCES_DIR}/VibeAnywareMenuIconTemplate.png"
fi

xml_escape() {
  printf '%s' "$1" | sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' \
    -e "s/'/\&apos;/g"
}

plist_env_pair() {
  local key="$1"
  local value="$2"
  if [[ -n "${value}" ]]; then
    printf '    <key>%s</key>\n    <string>%s</string>\n' "$(xml_escape "${key}")" "$(xml_escape "${value}")"
  fi
}

cat > "${APP_CONTENTS_DIR}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>VibeAnyware</string>
  <key>CFBundleExecutable</key>
  <string>VibeAnyware</string>
  <key>CFBundleIdentifier</key>
  <string>${LABEL}</string>
  <key>CFBundleIconFile</key>
  <string>${APP_ICON_NAME}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>VibeAnyware</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

if [[ -z "${CODESIGN_IDENTITY}" ]]; then
  CODESIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/^[[:space:]]*[0-9]+\)/ {print $2; exit}')"
fi
if [[ -z "${CODESIGN_IDENTITY}" ]]; then
  CODESIGN_IDENTITY="-"
  printf 'Warning: no code signing identity found; falling back to ad-hoc signing. Accessibility may need re-granting after each reinstall.\n' >&2
fi

/usr/bin/codesign --force --deep --sign "${CODESIGN_IDENTITY}" --identifier "${LABEL}" "${APP_DIR}" >/dev/null
xattr -dr com.apple.quarantine "${APP_DIR}" 2>/dev/null || true
if [[ -x "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister" ]]; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "${APP_DIR}" >/dev/null 2>&1 || true
fi

{
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(xml_escape "${HOST_BINARY}")</string>
    <string>$(xml_escape "${PORT}")</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
EOF
  plist_env_pair "VIBE_ANYWARE_LAN_COMMAND_KEY" "${LAN_COMMAND_KEY}"
  plist_env_pair "VIBE_ANYWARE_RELAY_ENDPOINT" "${RELAY_ENDPOINT}"
  plist_env_pair "VIBE_ANYWARE_RELAY_SERVER_ID" "${RELAY_SERVER_ID}"
  plist_env_pair "VIBE_ANYWARE_RELAY_ACCESS_TOKEN" "${RELAY_ACCESS_TOKEN}"
  plist_env_pair "VIBE_ANYWARE_RELAY_COMMAND_KEY" "${RELAY_COMMAND_KEY}"
  plist_env_pair "VIBE_ANYWARE_OFFICIAL_RELAY_SETUP_KEY" "${OFFICIAL_RELAY_SETUP_KEY}"
  cat <<EOF
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$(xml_escape "${LOG_DIR}/VibeAnyware.log")</string>
  <key>StandardErrorPath</key>
  <string>$(xml_escape "${LOG_DIR}/VibeAnyware.err.log")</string>
</dict>
</plist>
EOF
} > "${PLIST_PATH}"
chmod 600 "${PLIST_PATH}"

USER_DOMAIN="gui/$(id -u)"
launchctl enable "${USER_DOMAIN}/${LABEL}" >/dev/null 2>&1 || true
launchctl bootout "${USER_DOMAIN}/${LABEL}" >/dev/null 2>&1 || true
launchctl bootout "${USER_DOMAIN}" "${PLIST_PATH}" >/dev/null 2>&1 || true
launchctl bootstrap "${USER_DOMAIN}" "${PLIST_PATH}"
launchctl kickstart -k "${USER_DOMAIN}/${LABEL}"

default_interface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
lan_ip=""
if [[ -n "${default_interface}" ]]; then
  lan_ip="$(ipconfig getifaddr "${default_interface}" 2>/dev/null || true)"
fi
if [[ -z "${lan_ip}" ]]; then
  lan_ip="$(ipconfig getifaddr en0 2>/dev/null || true)"
fi
if [[ -z "${lan_ip}" ]]; then
  lan_ip="<LAN IP>"
fi

printf 'Installed %s\n' "${APP_DIR}"
printf 'LaunchAgent: %s\n' "${PLIST_PATH}"
printf 'Logs: %s and %s\n' "${LOG_DIR}/VibeAnyware.log" "${LOG_DIR}/VibeAnyware.err.log"
printf 'If the menu bar shows Accessibility: Missing, open System Settings -> Privacy & Security -> Accessibility and allow %s.\n' "${APP_DIR}"
printf 'Open the iOS app, switch to LAN, enter %s as Host and %s as Port.\n' "${lan_ip}" "${PORT}"
