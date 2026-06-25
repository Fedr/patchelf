#!/bin/bash
# NixOS/patchelf#639 on the real triggering binary
# (libpybind11nonlimitedapi_meshlib_3.12.so, MeshLib daily v3.1.2.247,
# 2026-05-16, clang-21). .init at 0x224, right after an 8-entry PHT ending at
# 0x200, DT_INIT=0x224. linuxdeploy reproduced it by APPENDING to the existing
# RUNPATH (a small bump that forces in-place PHT growth, overrunning .init).
#
# We sweep rpath sizes to find the in-place-growth trigger, then for that rpath
# compare control (pre-fix) vs fixed (PR #652): is DT_INIT kept in sync with the
# relocated .init? (readelf only; the shim's deps aren't on the runner.)
#
# Usage: verify.sh <patchelf-FIXED> <patchelf-CONTROL> <fixture.so.xz>
set -u
PE_FIXED="$1"; PE_CTRL="$2"; FIX="$3"
work="$(mktemp -d)"
xz -dc "$FIX" > "$work/orig.so"

init_addr(){ readelf -SW "$1" | awk '{for(i=1;i<=NF;i++) if($i==".init") print $(i+2)}'; }
dt_init(){ readelf -dW "$1" | awk '/\(INIT\)/{print $NF}'; }
orig_rpath(){ readelf -dW "$1" | awk '/\(RUNPATH\)|\(RPATH\)/{for(i=1;i<=NF;i++) if($i ~ /^\[/){gsub(/[][]/,"",$i); print $i}}'; }

sh0="$(init_addr "$work/orig.so")"; dt0="$(dt_init "$work/orig.so")"
base_rp="$(orig_rpath "$work/orig.so")"
echo "ORIGINAL: .init=0x$(printf %x $((16#$sh0)))  DT_INIT=$dt0  phnum=$(readelf -hW "$work/orig.so" | awk '/Number of program/{print $NF}')"
echo "base RUNPATH=$base_rp"
echo

probe() { # $1=patchelf $2=rpath ; echo "reloc match dt"
    local pe="$1" rp="$2" so="$work/t.so"
    cp "$work/orig.so" "$so"
    "$pe" --set-rpath "$rp" "$so" 2>/dev/null || { echo "ERR ERR ERR"; return; }
    local sh dt; sh="$(init_addr "$so")"; dt="$(dt_init "$so")"
    local moved=no; [ -n "$sh" ] && [ "$sh" != "$sh0" ] && moved=YES
    local match=no; [ -n "$sh" ] && [ "$((dt))" -eq "$((16#$sh))" ] && match=YES
    echo "$moved $match $dt"
}

# Sweep: append increasing suffixes to the existing rpath (mimics linuxdeploy).
trigger_rp=""
echo "=== sweep (CONTROL patchelf) — looking for .init relocation ==="
for n in 1 4 8 16 24 32 48 64 96 128 200 400; do
    suff=":\$ORIGIN/$(head -c $n /dev/zero | tr '\0' x)"
    rp="${base_rp}${suff}"
    read mv mt dt <<<"$(probe "$PE_CTRL" "$rp")"
    printf "  +%-4s chars: relocated=%s DT_INIT==.init?=%s DT_INIT=%s\n" "$n" "$mv" "$mt" "$dt"
    if [ "$mv" = YES ] && [ -z "$trigger_rp" ]; then trigger_rp="$rp"; trigger_n="$n"; fi
done
echo

if [ -z "$trigger_rp" ]; then
    echo "VERDICT: INCONCLUSIVE - no swept rpath made the control relocate .init"
    exit 3
fi

echo "=== TRIGGER found (rpath = base + ${trigger_n} chars) — control vs fixed ==="
read cmv cmt cdt <<<"$(probe "$PE_CTRL"  "$trigger_rp")"
read fmv fmt fdt <<<"$(probe "$PE_FIXED" "$trigger_rp")"
echo "  CONTROL: relocated=$cmv  DT_INIT=$cdt  DT_INIT==.init? $cmt"
echo "  FIXED:   relocated=$fmv  DT_INIT=$fdt  DT_INIT==.init? $fmt"
echo
echo "============================================================"
if [ "$cmt" = no ] && [ "$fmv" = YES ] && [ "$fmt" = YES ]; then
    echo "VERDICT: PASS - reproduced #639 on the real binary and confirmed the fix:"
    echo "  CONTROL relocates .init but leaves DT_INIT STALE (=$cdt) -> SIGSEGV on dlopen"
    echo "  FIXED (PR #652) relocates .init AND updates DT_INIT (=$fdt) -> correct"
    exit 0
fi
echo "VERDICT: control match=$cmt  fixed moved=$fmv match=$fmt (unexpected)"
exit 1
