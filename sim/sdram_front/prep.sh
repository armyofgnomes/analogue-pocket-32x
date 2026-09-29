#!/usr/bin/env bash
# Uses the same sim-only copy of the patched sdram.sv as sim/sdram.
set -euo pipefail
"$(dirname "$0")/../sdram/prep.sh"
