#!/usr/bin/env bash
# Simulation regression (REQ-QA-05): a few full-system runs with known results, in parallel.
#   padtest_*   the pad test program (sim/system/roms/make_padtest.py): Genesis path, 6-button pad
#               protocol, VDP backdrop; checks the screen color after 2 frames.
#   kolibri_*   Kolibri with FAST_BIOS to 60 ms: both SH-2s and the 68K through the 32X BIOS boot;
#               checks the BIOS-read signatures (any bus/memory timing change shows up here).
# Usage: sim/regress/run.sh     (KOLIBRI=<path to the Kolibri ROM>, default ~/Downloads/Kolibri*.32x)
# Takes ~20 minutes. Results and logs in build/sim/regress/. Exit status 1 on any mismatch.
set -uo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
out=$repo/build/sim/regress
mkdir -p "$out"
golden() { awk -v k="$1" '$1==k {print $2}' "$repo/sim/regress/golden.txt"; }

kolibri=${KOLIBRI:-$(ls ~/Downloads/Kolibri*.32x 2>/dev/null | head -1)}
[ -f "$kolibri" ] || { echo "error: Kolibri ROM not found (set KOLIBRI=...)"; exit 2; }
python3 "$repo/sim/system/roms/make_padtest.py" "$out/padtest.bin" >/dev/null

run() {   # name, env..., -- args...
    local name=$1; shift
    local envs=()
    while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
    env "${envs[@]}" WORK="$out/$name" "$repo/sim/system/run.sh" "$@" > "$out/$name.log" 2>&1
}
run padtest_6btn_x  -- "+rom=$out/padtest.bin" +pad6 +joy1=200 +frames=2 &
run padtest_6btn_yz -- "+rom=$out/padtest.bin" +pad6 +joy1=c00 +frames=2 &
run padtest_3btn    -- "+rom=$out/padtest.bin" +joy1=200 +frames=2 &
run kolibri FAST_BIOS=1 -- "+rom=$kolibri" +stop_ms=60 +sig_len=20000 &
wait

fail=0
check() {   # name, got
    local want; want=$(golden "$1")
    if [ "$2" = "$want" ]; then echo "PASS  $1 = $2"; else echo "FAIL  $1 = ${2:-<none>} (want $want)"; fail=1; fi
}
color() {   # most common pixel of frame_1 as rrggbb
    python3 - "$1" <<'PY'
import sys, collections
d = open(sys.argv[1], 'rb').read()
p = d.split(b'\n', 3)[3]                # after "P6\n<w> <h>\n255\n"
px = collections.Counter(p[i:i + 3] for i in range(0, len(p) - 2, 3))
print(px.most_common(1)[0][0].hex())
PY
}
for t in padtest_6btn_x padtest_6btn_yz padtest_3btn; do
    check "$t" "$( [ -f "$out/$t/frame_1.ppm" ] && color "$out/$t/frame_1.ppm")"
done
check kolibri_68k "$(sed -n 's/.*signature: 68K first 20000 reads \([0-9a-f]*\).*/\1/p' "$out/kolibri.log")"
check kolibri_sh2 "$(sed -n 's/.*signature: SH-2 first 20000 reads \([0-9a-f]*\).*/\1/p' "$out/kolibri.log")"
exit $fail
