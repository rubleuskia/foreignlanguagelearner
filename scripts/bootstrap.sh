#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -version
command -v xcodegen >/dev/null || { echo 'Install XcodeGen: brew install xcodegen' >&2; exit 1; }
xcodegen generate
