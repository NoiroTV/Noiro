#!/usr/bin/env bash
set -euo pipefail

mode="${1:-full}"
if [[ "$mode" != "full" && "$mode" != "--static" ]]; then
  echo "usage: $0 [--static]" >&2
  exit 64
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root"

failed=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1" >&2; failed=1; }

tracked_list="$(mktemp)"
trap 'rm -f "$tracked_list"' EXIT
while IFS= read -r -d '' file; do
  [[ -f "$file" ]] && printf '%s\0' "$file"
done < <(git ls-files -z --cached --others --exclude-standard) > "$tracked_list"

if command -v rg >/dev/null 2>&1; then
  search_tool="rg"
else
  search_tool="grep"
fi

scan_forbidden() {
  local label="$1"
  local pattern="$2"
  local result
  if [[ "$search_tool" == "rg" ]]; then
    result="$(xargs -0 rg -n -i --no-messages -- "$pattern" < "$tracked_list" || true)"
  else
    result="$(xargs -0 grep -I -n -i -E -- "$pattern" < "$tracked_list" || true)"
  fi
  if [[ -n "$result" ]]; then
    fail "$label"
    printf '%s\n' "$result" >&2
  else
    pass "$label"
  fi
}

scan_forbidden "no inherited legacy hosts" '([[:alnum:]-]+[.])?noiro[.]tv'
scan_forbidden "no inherited edge secret identifier" 'NOIRO[_-]EDGE[_-]SECRET'
scan_forbidden "no old owner repository links" 'NoiroTV[/]Noiro'

if git ls-files --error-unmatch app/Resources/server.js >/dev/null 2>&1; then
  fail "proprietary server.js is not tracked"
else
  pass "proprietary server.js is not tracked"
fi

for retired in altstore/source.json altstore/README.md scripts/gen-altstore-source.py .github/workflows/release-tvos.yml; do
  if [[ -e "$retired" ]]; then
    fail "retired direct-install/release artifact removed: $retired"
  else
    pass "retired direct-install/release artifact removed: $retired"
  fi
done

require_text() {
  local file="$1"
  local text="$2"
  local label="$3"
  local matched=1
  if [[ "$search_tool" == "rg" ]]; then
    if [[ -f "$file" ]] && rg -q -F -- "$text" "$file"; then matched=0; fi
  else
    if [[ -f "$file" ]] && grep -q -F -- "$text" "$file"; then matched=0; fi
  fi
  if [[ "$matched" -eq 0 ]]; then pass "$label"; else fail "$label"; fi
}

require_text app/project.yml 'PRODUCT_BUNDLE_IDENTIFIER: com.elvissalihovic.noiro' "canonical iOS identifier"
require_text app/project.yml 'PRODUCT_BUNDLE_IDENTIFIER: com.elvissalihovic.noiro.tvos' "canonical tvOS identifier"
require_text app/project.yml 'PRODUCT_BUNDLE_IDENTIFIER: com.elvissalihovic.noiro.macos' "canonical macOS identifier"
require_text app/project.yml 'group.com.elvissalihovic.noiro' "canonical app group"
require_text app/project.yml 'NoiroTV:' "NoiroTV target"
require_text app/project.yml 'NoiroMac:' "NoiroMac target"
require_text LICENSE 'GNU GENERAL PUBLIC LICENSE' "GPL license"
require_text docs/GPL_SOURCE_AND_DISTRIBUTION.md 'exact corresponding-source archive' "corresponding-source policy"
require_text docs/INSTALLATION.md 'never asks for an Apple ID' "no Apple credential collection"

if [[ "$failed" -ne 0 ]]; then
  echo "Static Noiro release gate failed." >&2
  exit 1
fi

if [[ "$mode" == "--static" ]]; then
  echo "Static Noiro release gate passed. This does not authorize a release."
  exit 0
fi

if ! git diff --quiet || ! git diff --cached --quiet || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
  fail "release tree is clean and committed"
else
  pass "release tree is clean and committed"
fi

approval_result="$(python3 - <<'PY'
import json
from pathlib import Path

path = Path("release/noiro-release-approvals.json")
try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except Exception as exc:
    print(f"invalid approvals file: {exc}")
    raise SystemExit(2)

missing = []
for name, record in payload.get("approvals", {}).items():
    if record.get("approved") is not True or not str(record.get("evidence", "")).strip():
        missing.append(name)
if payload.get("release_allowed") is not True:
    missing.append("release_allowed")
if missing:
    print("unapproved: " + ", ".join(missing))
    raise SystemExit(1)
print("all recorded approvals contain evidence")
PY
)" || {
  fail "$approval_result"
}
[[ "$failed" -eq 0 ]] && pass "$approval_result"

if [[ "$failed" -ne 0 ]]; then
  echo "Full Noiro release gate remains closed." >&2
  exit 1
fi

echo "Full Noiro release gate passed. Preserve this output with the signed release record."
