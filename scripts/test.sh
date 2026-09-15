#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/bootstrap.sh
mkdir -p build
# Pick an available iPhone instead of depending on a particular device model.
if [[ -z "${SIMULATOR_ID:-}" ]]; then
  SIMULATOR_ID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
runtimes = json.load(sys.stdin)["devices"]
for runtime in sorted(runtimes, reverse=True):
    if "iOS" in runtime:
        for device in runtimes[runtime]:
            if device["name"].startswith("iPhone"):
                print(device["udid"])
                sys.exit(0)
sys.exit("No available iPhone simulator. Install an iOS runtime in Xcode Settings.")
')
fi
xcodebuild test \
  -project ForeignLanguageLearner.xcodeproj \
  -scheme ForeignLanguageLearner \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath build/DerivedData \
  -resultBundlePath "build/Tests-$(date +%Y%m%d-%H%M%S).xcresult" \
  -enableCodeCoverage YES CODE_SIGNING_ALLOWED=NO
