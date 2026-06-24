#!/bin/bash
# Verify NixOS/patchelf#639 against the real MeshLib shim built with several
# linkers (the triggering layout - .init right after the PHT - is linker/
# version dependent; issue #639 saw it with lld, commenter saw it with bfd).
#
# Usage: verify.sh <patchelf-FIXED> <patchelf-CONTROL> <ld-library-path> <shim.so>...
#
# Primary signal: does --set-rpath relocate .init? If so, does the FIXED build
# keep DT_INIT == .init (the PR #652 fix)? dlopen is attempted as a bonus but
# its dependency resolution (libpython etc.) is not allowed to mask the result.
set -u

PE_FIXED="$1"; PE_CTRL="$2"; LIBPATH="$3"; shift 3
SHIMS=("$@")
work="$(mktemp -d)"

# Make the stub dependency resolvable for dlopen + $ORIGIN.
IFS=':' read -ra LDDIRS <<< "$LIBPATH"
for d in "${LDDIRS[@]}"; do cp "$d"/libpybind11nonlimitedapi_stubs.so "$work/" 2>/dev/null || true; done
export LD_LIBRARY_PATH="$work:$LIBPATH"

cat > "$work/dlopen.c" <<'EOF'
#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char **argv){ void*h=dlopen(argv[1],RTLD_LAZY);
  if(!h){fprintf(stderr,"dlopen note: %s\n",dlerror());return 2;} return 0; }
EOF
cc -O2 -o "$work/dlopen" "$work/dlopen.c" -ldl

init_shaddr(){ readelf -SW "$1" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i==".init") print $(i+2)}'; }
dt_init(){ readelf -dW "$1" 2>/dev/null | awk '/\(INIT\)/{print $NF}'; }
dlopen_rc(){ cp "$1" "$work/cur.so"; ( cd "$work" && ./dlopen ./cur.so >/dev/null 2>&1 ); echo $?; }

trigger_found=0; fix_broken=0
for LIB in "${SHIMS[@]}"; do
    [ -f "$LIB" ] || { echo "## MISSING: $LIB (linker build failed)"; echo; continue; }
    name="$(basename "$LIB")"
    echo "################ $name ($(stat -c%s "$LIB") bytes) ################"
    echo "-- first LOAD segments + section order --"
    readelf -lW "$LIB" | awk '/Type +Offset/{p=1} p&&/LOAD|PHDR/{print} /Section to Segment/{p=0}'
    readelf -lW "$LIB" | awk '/02 +/{print "  exec-seg sections:",$0}' | head -1
    sh0="$(init_shaddr "$LIB")"; dt0="$(dt_init "$LIB")"
    echo "  baseline: .init sh_addr=$sh0  DT_INIT=$dt0"

    for tag in SHORT LONG; do
        [ "$tag" = SHORT ] && RP="\$ORIGIN" || RP="\$ORIGIN/$(head -c 6000 /dev/zero | tr '\0' x)"
        cp "$LIB" "$work/fixed.so"; PATCHELF_DEBUG=1 "$PE_FIXED" --set-rpath "$RP" "$work/fixed.so" 2>"$work/f.dbg"
        cp "$LIB" "$work/ctrl.so";  "$PE_CTRL"  --set-rpath "$RP" "$work/ctrl.so" 2>/dev/null || true
        shF="$(init_shaddr "$work/fixed.so")"; dtF="$(dt_init "$work/fixed.so")"
        shC="$(init_shaddr "$work/ctrl.so")";  dtC="$(dt_init "$work/ctrl.so")"
        moved=no; [ -n "$shF" ] && [ "$sh0" != "$shF" ] && moved=YES
        matchF=n/a; [ -n "$shF" ] && { [ "$((dtF))" -eq "$((16#$shF))" ] && matchF=YES || matchF=no; }
        matchC=n/a; [ -n "$shC" ] && { [ "$((dtC))" -eq "$((16#$shC))" ] && matchC=YES || matchC=no; }
        rcF="$(dlopen_rc "$work/fixed.so")"; rcC="$(dlopen_rc "$work/ctrl.so")"
        dec="$(grep -iE 'reloc|allocating|shifting' "$work/f.dbg" | paste -sd'; ' -)"
        echo "  [$tag] reloc=$moved  decision='$dec'"
        echo "        .init fixed=$shF ctrl=$shC | DT_INIT fixed=$dtF ctrl=$dtC | match fixed=$matchF ctrl=$matchC | dlopen fixed=$rcF ctrl=$rcC"
        if [ "$moved" = YES ]; then
            trigger_found=1
            [ "$matchF" = YES ] || { fix_broken=1; echo "        *** FIX FAILED: DT_INIT not synced ($name/$tag) ***"; }
        fi
    done
    echo
done

echo "============================================================"
if [ "$trigger_found" -eq 0 ]; then
    echo "VERDICT: INCONCLUSIVE - no linker produced a layout where --set-rpath relocates .init"
    exit 3
fi
[ "$fix_broken" -eq 1 ] && { echo "VERDICT: FAIL - PR #652 left DT_INIT stale in a triggering case"; exit 1; }
echo "VERDICT: PASS - whenever .init was relocated, PR #652 kept DT_INIT in sync with it"
exit 0
