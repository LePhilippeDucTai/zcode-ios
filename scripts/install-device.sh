#!/bin/zsh
# Builds ZCode and installs it on the paired iPhone (USB, or Wi-Fi on the same network).
# Free Apple account: the provisioning profile expires after 7 days, so rerun this script weekly.
# One-time prerequisites (see README.md): Config/Signing.local.xcconfig, Apple ID in Xcode → Settings → Accounts,
# paired iPhone with Developer Mode on, first launch from Xcode and developer trusted in the iPhone's Settings.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [[ ! -f Config/Signing.local.xcconfig ]]; then
  echo "Config/Signing.local.xcconfig is missing: copy Config/Signing.local.xcconfig.example to it and set DEVELOPMENT_TEAM and ZCODE_BUNDLE_ID_PREFIX." >&2
  exit 1
fi
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found in PATH (install it with: brew install xcodegen)." >&2
  exit 1
fi

devices_json=$(mktemp)
trap 'rm -f "$devices_json"' EXIT
xcrun devicectl list devices --json-output "$devices_json" >/dev/null

# First physical iPhone: devicectl identifier, then UDID (for xcodebuild).
device="" udid=""
read -r device udid < <(python3 - "$devices_json" <<'PY'
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    hw = d.get("hardwareProperties", {})
    if hw.get("reality") == "physical" and hw.get("platform") == "iOS":
        print(d["identifier"], hw.get("udid", ""))
        break
PY
) || true
if [[ -z "$device" || -z "$udid" ]]; then
  echo "No paired iPhone found: connect and unlock it, then try again." >&2
  exit 1
fi

APP=build/DeviceData/Build/Products/Debug-iphoneos/ZCode.app
xcodegen generate --quiet
xcodebuild build -project ZCode.xcodeproj -scheme ZCode -configuration Debug \
  -destination "id=$udid" -derivedDataPath build/DeviceData -allowProvisioningUpdates -quiet
xcrun devicectl device install app --device "$device" "$APP"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
xcrun devicectl device process launch --device "$device" "$bundle_id"
echo "ZCode ($bundle_id) installed and launched on the iPhone."
