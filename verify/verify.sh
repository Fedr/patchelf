#!/bin/bash
# Verify NixOS/patchelf#639 against the REAL MeshLib shim
# (libpybind11nonlimitedapi_meshlib_3.12.so), built standalone from the pinned
# mrbind-pybind11 submodule with clang+lld - the same toolchain MeshLib uses.
#
# Usage: verify.sh <patchelf-FIXED> <patchelf-CONTROL> <real-shim.so>
#
# We mimic linuxdeploy by running --set-rpath with a few rpath lengths and
# compare the PR #652 build vs the pre-fix parent. dlopen uses RTLD_LAZY so the
# load reaches the .init constructor (where #639 crashes) without first failing
# on the shim's intentionally-undefined Python symbols.
set -u

PE_FIXED="$1"; PE_CTRL="$2"; LIB="$3"
work="$(mktemp -d)"

cat > "$work/dlopen.c" <<'EOF'
#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char **argv){
    void *h = dlopen(argv[1], RTLD_LAZY);
    if(!h){ fprintf(stderr,"dlopen FAILED: %s\n", dlerror()); return 2; }
    return 0;
}
EOF
cc -O2 -o "$work/dlopen" "$work/dlopen.c" -ldl

init_shaddr(){ readelf -SW "$1" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i==".init") print $(i+2)}'; }
dt_init(){ readelf -dW "$1" 2>/dev/null | awk '/\(INIT\)/{print $NF}'; }
dlopen_rc(){ cp "$1" "$work/cur.so"; ( cd "$work" && ./dlopen "$work/cur.so" ); echo $?; }

echo "############ REAL shim: $(basename "$LIB") ($(stat -c%s "$LIB") bytes) ############"
echo "---- original program headers ----"
readelf -lW "$LIB" | sed -n '1,32p'
echo "---- original sections (low offsets + dyn) ----"
readelf -SW "$LIB" | awk 'NR<=5 || /\.(init|fini|plt|text|note|dynstr|dynsym|gnu\.hash|hash|dynamic)\b/'
sh0="$(init_shaddr "$LIB")"; dt0="$(dt_init "$LIB")"
echo "==> baseline: .init sh_addr=$sh0  DT_INIT=$dt0"
echo

trigger_found=0; fix_broken=0
for rp in '$ORIGIN' '$ORIGIN:PAD200' '$ORIGIN:PAD6000'; do
    case "$rp" in
      *PAD200)  RP="\$ORIGIN/$(head -c 200  /dev/zero | tr '\0' x)";;
      *PAD6000) RP="\$ORIGIN/$(head -c 6000 /dev/zero | tr '\0' x)";;
      *)        RP="\$ORIGIN";;
    esac
    cp "$LIB" "$work/fixed.so"; PATCHELF_DEBUG=1 "$PE_FIXED" --set-rpath "$RP" "$work/fixed.so" 2>"$work/f.dbg"
    cp "$LIB" "$work/ctrl.so";  "$PE_CTRL"  --set-rpath "$RP" "$work/ctrl.so" 2>/dev/null || true

    shF="$(init_shaddr "$work/fixed.so")"; dtF="$(dt_init "$work/fixed.so")"
    shC="$(init_shaddr "$work/ctrl.so")";  dtC="$(dt_init "$work/ctrl.so")"
    moved=no; [ -n "$shF" ] && [ "$sh0" != "$shF" ] && moved=YES
    matchF=n/a; [ -n "$shF" ] && { [ "$((dtF))" -eq "$((16#$shF))" ] && matchF=YES || matchF=no; }
    matchC=n/a; [ -n "$shC" ] && { [ "$((dtC))" -eq "$((16#$shC))" ] && matchC=YES || matchC=no; }
    rcF="$(dlopen_rc "$work/fixed.so")"; rcC="$(dlopen_rc "$work/ctrl.so")"

    echo "==== rpath=$rp ===="
    echo "  patchelf decision (fixed): $(grep -iE 'reloc|phdr|segment|allocating|shifting' "$work/f.dbg" | paste -sd'; ' -)"
    echo "  .init sh_addr : fixed=$shF ctrl=$shC   (relocated=$moved)"
    echo "  DT_INIT       : fixed=$dtF ctrl=$dtC"
    echo "  DT_INIT==.init: fixed=$matchF ctrl=$matchC"
    echo "  dlopen rc     : fixed=$rcF ctrl=$rcC   (0=ok 139=SIGSEGV 2=dlopen-null)"
    echo
    if [ "$moved" = YES ]; then
        trigger_found=1
        { [ "$matchF" = YES ] && [ "$rcF" = 0 ]; } || { fix_broken=1; echo "  *** FIX FAILED (rpath=$rp matchF=$matchF rcF=$rcF) ***"; }
    fi
done

echo "============================================================"
if [ "$trigger_found" -eq 0 ]; then
    echo "VERDICT: INCONCLUSIVE - --set-rpath never relocated .init on the real shim"
    echo "         (see layout above; may need MeshLib's exact link flags)"
    exit 3
fi
if [ "$fix_broken" -eq 1 ]; then
    echo "VERDICT: FAIL - PR #652 did not fix at least one triggering case"; exit 1
fi
echo "VERDICT: PASS - on the real shim, PR #652 keeps DT_INIT synced with the relocated .init and dlopen succeeds"
exit 0
