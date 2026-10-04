#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v node >/dev/null || ! command -v xcodegen >/dev/null; then
  echo "Install Node.js 22+ and XcodeGen before building." >&2
  exit 1
fi
if [ ! -d bridge/node_modules ]; then
  (cd bridge && npm ci --no-audit --no-fund)
fi
mkdir -p DevFlow/Resources/bridge
rsync -a --delete bridge/ DevFlow/Resources/bridge/
(cd DevFlow && xcodegen generate)
xcodebuild -project DevFlow/DevFlow.xcodeproj -scheme DevFlow -configuration Debug \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
# Locally sign the internal bundle; this is not a Developer ID distribution
# or notarization step and does not require a signing certificate.
codesign --force --sign - --identifier dev.devflow.companion build/Build/Products/Debug/DevFlow.app
echo "Built: $(pwd)/build/Build/Products/Debug/DevFlow.app"
