#!/usr/bin/env bash
set -euo pipefail

echo "Noiro does not patch the proprietary Stremio server or inject inherited trailer credentials." >&2
echo "Use a rights-reviewed official direct trailer URL adapter after the release gate is approved." >&2
exit 1
