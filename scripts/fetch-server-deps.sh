#!/usr/bin/env bash
set -euo pipefail

cat >&2 <<'EOF'
Noiro does not download inherited release binaries or proprietary server.js.

Development work may use already-audited local dependencies in app/Vendor and
an ignored local server.js, but customer packaging remains blocked until:
  1. every binary dependency has a reviewed origin, checksum, license, and
     corresponding source where required; and
  2. server.js has written commercial redistribution/GPL-compatibility
     permission or has been replaced by a compatible open-source implementation.

Record approved replacements in docs/DEPENDENCY_AND_ASSET_AUDIT.md and update
release/Package.resolved before changing this script.
EOF
exit 1
