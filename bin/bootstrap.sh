#!/usr/bin/env bash
# Generates Flotsam.xcodeproj from project.yml and resolves packages (ADR-0012).
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required: brew install xcodegen" >&2
  exit 1
fi
xcodegen generate --spec project.yml
swift package --package-path Packages/FlotsamCore resolve
