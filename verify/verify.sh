#!/bin/bash
# Definitive NixOS/patchelf#639 verification on the REAL triggering binary:
# libpybind11nonlimitedapi_meshlib_3.12.so from MeshLib daily draft release
# v3.1.2.247 (built 2026-05-16, clang-21/lld-21). Its .init sits at 0x224,
# right after an 8-entry PHT that ends at 0x200, with DT_INIT=0x224 (valid).
#
# A --set-rpath that forces a 9th PT_LOAD grows the PHT past 0x224 and
# relocates .init. We prove the bug + fix by reading DT_INIT vs .init's new
# address (no dlopen: the shim's deps aren't on the runner, but the stale
# DT_INIT is the root cause and is directly observable).
#
# Usage: verify.sh <patchelf-FIXED> <patchelf-CONTROL> <fixture.so.xz>
set -u
PE_FIXED="$1"; PE_CTRL="$2"; FIX="$3"
work="$(mktemp -d)"
xz -dc "$FIX" > "$work/orig.so"

init_addr(){ readelf -SW "$1" | awk '{for(i=1;i<=NF;i++) if($i==".init") print $(i+2)}'; }
dt_init(){ readelf -dW "$1" | awk '/\(INIT\)/{print $NF}'; }

sh0="$(init_addr "$work/orig.so")"; dt0="$(dt_init "$work/orig.so")"
echo "ORIGINAL: .init=0x$(printf %x $((16#$sh0)))  DT_INIT=$dt0  (valid input)"
echo "PHT:"; readelf -hW "$work/orig.so" | grep -iE "Number of program|Start of program"
echo

# Long rpath to force a new PT_LOAD (PHT growth) -> .init relocation.
RP="\$ORIGIN/$(head -c 4000 /dev/zero | tr '\0' x)"

run() {
    local pe="$1" label="$2"
    cp "$work/orig.so" "$work/$label.so"
    "$pe" --set-rpath "$RP" "$work/$label.so" 2>"$work/$label.err" || { echo "$label: patchelf FAILED: $(cat "$work/$label.err")"; return; }
    local sh dt; sh="$(init_addr "$work/$label.so")"; dt="$(dt_init "$work/$label.so")"
    local moved=no; [ "$sh" != "$sh0" ] && moved=YES
    local match=no; [ -n "$sh" ] && [ "$((dt))" -eq "$((16#$sh))" ] && match=YES
    echo "$label: .init 0x$(printf %x $((16#$sh0))) -> 0x$(printf %x $((16#$sh)))  (relocated=$moved) | DT_INIT=$dt | DT_INIT==.init? $match"
    eval "${label}_moved=$moved; ${label}_match=$match"
}

run "$PE_CTRL"  CONTROL
run "$PE_FIXED" FIXED
echo
echo "============================================================"
# Expected: both relocate .init; CONTROL leaves DT_INIT stale (no), FIXED syncs it (yes).
if [ "${CONTROL_moved:-no}" != YES ] || [ "${FIXED_moved:-no}" != YES ]; then
    echo "VERDICT: INCONCLUSIVE - --set-rpath did not relocate .init (PHT didn't grow into it)"
    exit 3
fi
if [ "${CONTROL_match:-}" = no ] && [ "${FIXED_match:-}" = YES ]; then
    echo "VERDICT: PASS - reproduced #639 on the real binary:"
    echo "  CONTROL (pre-fix patchelf) relocates .init but leaves DT_INIT STALE -> SIGSEGV on dlopen"
    echo "  FIXED   (PR #652)          relocates .init AND updates DT_INIT -> correct"
    exit 0
fi
echo "VERDICT: UNEXPECTED - CONTROL_match=${CONTROL_match:-} FIXED_match=${FIXED_match:-}"
exit 1
