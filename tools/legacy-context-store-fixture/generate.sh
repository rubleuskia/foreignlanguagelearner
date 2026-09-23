#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."

OUTPUT_DIRECTORY="${1:-Tests/Fixtures/FoundationModelsLegacyStore}"
GENERATOR_DIRECTORY="tools/legacy-context-store-fixture"
DERIVED_DATA="$GENERATOR_DIRECTORY/build/DerivedData"

xcodegen generate --spec "$GENERATOR_DIRECTORY/project.yml" \
  --project "$GENERATOR_DIRECTORY"
xcodebuild build \
  -project "$GENERATOR_DIRECTORY/LegacyContextStoreGenerator.xcodeproj" \
  -scheme LegacyContextStoreGenerator \
  -configuration Debug \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO

"$DERIVED_DATA/Build/Products/Debug/LegacyContextStoreGenerator" "$OUTPUT_DIRECTORY"
