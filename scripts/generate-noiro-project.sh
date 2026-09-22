#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root/app"

command -v xcodegen >/dev/null 2>&1 || {
  echo "XcodeGen is required: https://github.com/yonaskolb/XcodeGen" >&2
  exit 1
}

xcodegen generate --spec project.yml
lock_dir="Noiro.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$lock_dir"
cp "$repo_root/release/Package.resolved" "$lock_dir/Package.resolved"

echo "Generated app/Noiro.xcodeproj with the reviewed Swift package lock."
