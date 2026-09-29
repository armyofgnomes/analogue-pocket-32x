#!/usr/bin/env bash
# The VDP sources are compiled from the sim-only rewritten copies that sim/system/gen_files.py
# writes to build/sim/hoisted/ (patched upstream, declarations hoisted).
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
"$repo/tools/prepare_upstream.sh" >/dev/null
python3 "$repo/sim/system/gen_files.py" >/dev/null
