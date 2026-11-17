#!/usr/bin/env bash
# Debug build into ./build (gitignored). Unsigned: release signing happens outside the repo.
set -euo pipefail
cd "$(dirname "$0")/.."
bin/bootstrap.sh
xcodebuild -project Flotsam.xcodeproj -scheme Flotsam -configuration Debug \
  -derivedDataPath build -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
