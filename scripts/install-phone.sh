#!/usr/bin/env bash
# Build, sign (free Personal Team is fine) and install HHT on the connected iPhone.
# Re-run every ≤7 days with a free Apple ID to renew the signature; app data is kept.
set -euo pipefail
cd "$(dirname "$0")/.."

tmp=$(mktemp)
xcrun devicectl list devices --json-output "$tmp" >/dev/null
udid=$(python3 - "$tmp" <<'PY'
import json, sys
devs = json.load(open(sys.argv[1]))["result"]["devices"]
phones = [d for d in devs
          if d.get("hardwareProperties", {}).get("reality") == "physical"
          and d.get("hardwareProperties", {}).get("platform") == "iOS"
          and d.get("connectionProperties", {}).get("tunnelState") != "unavailable"]
print(phones[0]["hardwareProperties"]["udid"] if phones else "")
PY
)
rm -f "$tmp"
if [[ -z "$udid" ]]; then
  echo "No iPhone found. Connect it by cable, unlock it, tap 'Trust', and make sure Developer Mode is on." >&2
  exit 1
fi
echo "→ Building for iPhone $udid"
xcodebuild -project HHT.xcodeproj -scheme HHT -destination "id=$udid" \
  -derivedDataPath .build-xcode/phone -allowProvisioningUpdates build | grep -E "error:|BUILD" || true
app=.build-xcode/phone/Build/Products/Debug-iphoneos/HHT.app
[[ -d "$app" ]] || { echo "Build failed (see above)." >&2; exit 1; }
echo "→ Installing"
xcrun devicectl device install app --device "$udid" "$app" >/dev/null
echo "✓ Installed. Data on the phone is preserved."
