#!/bin/bash
set -euo pipefail
: "${RUNNER_TEMP:?}" "${GITHUB_ENV:?}" "${IOS_CERTIFICATE_BASE64:?}" "${IOS_CERTIFICATE_PASSWORD:?}" "${IOS_PROFILE_BASE64:?}"
KEYCHAIN_PATH="$RUNNER_TEMP/ios-signing.keychain-db"
KEYCHAIN_PASSWORD=$(openssl rand -hex 24)
echo "::add-mask::$KEYCHAIN_PASSWORD"
echo "KEYCHAIN_PATH=$KEYCHAIN_PATH" >> "$GITHUB_ENV"
python3 - <<'PY'
import base64, os
from pathlib import Path
for key, name in [('IOS_CERTIFICATE_BASE64', 'distribution.p12'), ('IOS_PROFILE_BASE64', 'profile.mobileprovision')]:
    path = Path(os.environ['RUNNER_TEMP']) / name
    path.write_bytes(base64.b64decode(os.environ[key], validate=True))
    path.chmod(0o600)
PY
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$RUNNER_TEMP/distribution.p12" -P "$IOS_CERTIFICATE_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN_PATH"
security set-key-partition-list -S apple-tool:,apple:,codesign: -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null
security list-keychains -d user -s "$KEYCHAIN_PATH" login.keychain-db
security cms -D -i "$RUNNER_TEMP/profile.mobileprovision" > "$RUNNER_TEMP/profile.plist"
python3 - <<'PY'
import os, plistlib, shutil
from pathlib import Path
with open(Path(os.environ['RUNNER_TEMP']) / 'profile.plist', 'rb') as file:
    profile = plistlib.load(file)
identifier = profile['Entitlements']['application-identifier']
if identifier != os.environ['APPLE_TEAM_ID'] + '.' + os.environ['APP_IDENTIFIER']:
    raise SystemExit('Provisioning profile does not match team and bundle identifier')
if 'ProvisionedDevices' in profile or profile.get('ProvisionsAllDevices'):
    raise SystemExit('An App Store distribution provisioning profile is required')
name = profile['Name']
if '\n' in name or '\r' in name:
    raise SystemExit('Invalid profile name')
destination = Path.home() / 'Library/MobileDevice/Provisioning Profiles' / (profile['UUID'] + '.mobileprovision')
destination.parent.mkdir(parents=True, exist_ok=True)
shutil.copyfile(Path(os.environ['RUNNER_TEMP']) / 'profile.mobileprovision', destination)
with open(os.environ['GITHUB_ENV'], 'a') as file:
    file.write(f'PROFILE_NAME={name}\nPROFILE_PATH={destination}\n')
PY
