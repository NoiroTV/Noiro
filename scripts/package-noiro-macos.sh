#!/usr/bin/env bash
set -euo pipefail

version="${1:-}"
output_dir="${2:-}"
if [[ -z "$version" || -z "$output_dir" ]]; then
  echo "usage: $0 <version> <output-directory>" >&2
  exit 64
fi
: "${NOIRO_DEVELOPER_ID_APPLICATION:?Set the Developer ID Application identity name}"
: "${NOIRO_NOTARY_PROFILE:?Set the notarytool keychain profile name}"

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root"
scripts/noiro-release-gate.sh
scripts/generate-noiro-project.sh

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
archive="$work/Noiro.xcarchive"

xcodebuild -project app/Noiro.xcodeproj -scheme NoiroMac -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$archive" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$NOIRO_DEVELOPER_ID_APPLICATION" archive

app_path="$archive/Products/Applications/Noiro.app"
codesign --verify --deep --strict --verbose=2 "$app_path"
mkdir -p "$output_dir"
zip_path="$output_dir/Noiro-${version}-macOS.zip"
ditto -c -k --keepParent "$app_path" "$zip_path"
xcrun notarytool submit "$zip_path" --keychain-profile "$NOIRO_NOTARY_PROFILE" --wait
xcrun stapler staple "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
spctl --assess --type execute --verbose=2 "$app_path"
ditto -c -k --keepParent "$app_path" "$zip_path"
shasum -a 256 "$zip_path" > "$zip_path.sha256"
echo "Created signed and notarized $zip_path"
