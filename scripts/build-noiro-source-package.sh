#!/usr/bin/env bash
set -euo pipefail

version="${1:-}"
output_dir="${2:-}"
if [[ -z "$version" || -z "$output_dir" ]]; then
  echo "usage: $0 <version> <output-directory>" >&2
  exit 64
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root"
scripts/noiro-release-gate.sh --static

if ! git diff --quiet || ! git diff --cached --quiet || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
  echo "source packages must come from a clean, committed tree" >&2
  exit 1
fi

mkdir -p "$output_dir"
commit="$(git rev-parse HEAD)"
archive="$output_dir/Noiro-${version}-source-${commit:0:12}.tar.gz"
git archive --format=tar.gz --prefix="Noiro-${version}/" --output="$archive" HEAD
shasum -a 256 "$archive" > "$archive.sha256"
echo "Created $archive from $commit"
