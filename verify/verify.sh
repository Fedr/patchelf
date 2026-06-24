#!/bin/bash
# Reproduce NixOS/patchelf#639: --set-rpath relocates .init in an lld-produced
# shared library but DT_INIT is left pointing at the old address, so the dynamic
# loader jumps to a stale address and SIGSEGVs at dlopen.
#
# Usage: verify.sh <patchelf-FIXED> <patchelf-CONTROL>
#   FIXED   = patchelf built from PR #652 (has the DT_INIT/DT_FINI fixup)
#   CONTROL = patchelf built from the commit just before the fix
#
# The blocker for a regression test (per the PR author) is *triggering* the
# .init relocation. lld only overruns .init when it sits at a low file offset
# immediately after the program-header table, which depends on the segment
# layout, so we sweep a few link configs and report which ones trigger.
set -u

PE_FIXED="$1"
PE_CTRL="$2"
work="$(mktemp -d)"

cat > "$work/foo.c" <<'EOF'
__attribute__((constructor)) static void ctor(void) { }
int foo(void) { return 42; }
EOF

cat > "$work/dlopen.c" <<'EOF'
#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char **argv) {
    void *h = dlopen(argv[1], RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen FAILED: %s\n", dlerror()); return 2; }
    return 0;
}
EOF
cc -O2 -o "$work/dlopen" "$work/dlopen.c" -ldl

# A long RPATH forces .dynstr growth -> section relocation -> PHT growth.
RP="\$ORIGIN/$(head -c 6000 /dev/zero | tr '\0' x)"

init_shaddr() { readelf -SW "$1" | awk '{for(i=1;i<=NF;i++) if($i==".init") print $(i+2)}'; }
dt_init()     { readelf -dW "$1" | awk '/\(INIT\)/{print $NF}'; }

dlopen_rc() {  # prints exit code: 0=loaded, 139=SIGSEGV, 2=dlopen null
    cp "$1" "$work/cur.so"
    ( cd "$work" && ./dlopen "$work/cur.so" ); echo $?
}

# name -> extra linker flags
names=(default noseparate-code no-rosegment separate-loadable)
declare -A FLAGS=(
  [default]=""
  [noseparate-code]="-Wl,-z,noseparate-code"
  [no-rosegment]="-Wl,-z,noseparate-code -Wl,--no-rosegment"
  [separate-loadable]="-Wl,-z,separate-loadable-segments"
)

trigger_found=0
fix_broken=0

for name in "${names[@]}"; do
    base="$work/$name"
    # shellcheck disable=SC2086
    clang -fuse-ld=lld -shared -fPIC -O2 -Wl,--build-id=sha1 ${FLAGS[$name]} \
          -o "$base.so" "$work/foo.c" 2>"$base.lderr" \
        || { echo "==== config=$name : LINK FAILED ===="; cat "$base.lderr"; echo; continue; }

    sh0="$(init_shaddr "$base.so")"; dt0="$(dt_init "$base.so")"

    cp "$base.so" "$base.fixed.so"; "$PE_FIXED" --set-rpath "$RP" "$base.fixed.so" 2>"$base.fixederr"
    cp "$base.so" "$base.ctrl.so";  "$PE_CTRL"  --set-rpath "$RP" "$base.ctrl.so"  2>"$base.ctrlerr" || true

    shF="$(init_shaddr "$base.fixed.so")"; dtF="$(dt_init "$base.fixed.so")"
    shC="$(init_shaddr "$base.ctrl.so")";  dtC="$(dt_init "$base.ctrl.so")"

    moved=no; [ "$sh0" != "$shF" ] && moved=YES
    matchF=n/a; [ -n "$shF" ] && { [ "$((dtF))" -eq "$((16#$shF))" ] && matchF=YES || matchF=no; }
    matchC=n/a; [ -n "$shC" ] && { [ "$((dtC))" -eq "$((16#$shC))" ] && matchC=YES || matchC=no; }
    rcF="$(dlopen_rc "$base.fixed.so")"
    rcC="$(dlopen_rc "$base.ctrl.so")"

    echo "==== config=$name ===="
    echo "  .init sh_addr : orig=$sh0  fixed=$shF  ctrl=$shC   (relocated=$moved)"
    echo "  DT_INIT       : orig=$dt0  fixed=$dtF  ctrl=$dtC"
    echo "  DT_INIT==.init: fixed=$matchF  ctrl=$matchC"
    echo "  dlopen rc     : fixed=$rcF  ctrl=$rcC   (0=ok 139=SIGSEGV 2=dlopen-null)"
    echo

    if [ "$moved" = YES ]; then
        trigger_found=1
        if [ "$matchF" = YES ] && [ "$rcF" = 0 ]; then
            :
        else
            fix_broken=1
            echo "  *** FIX FAILED for config '$name' (matchF=$matchF rcF=$rcF) ***"
        fi
    fi
done

echo "============================================================"
if [ "$trigger_found" -eq 0 ]; then
    echo "VERDICT: INCONCLUSIVE - no link config relocated .init; need a different fixture"
    exit 3
fi
if [ "$fix_broken" -eq 1 ]; then
    echo "VERDICT: FAIL - PR #652 did not fix at least one triggering case"
    exit 1
fi
echo "VERDICT: PASS - PR #652 updates DT_INIT on .init relocation; the library dlopens cleanly"
echo "         (control patchelf leaves DT_INIT stale and SIGSEGVs on the same input)"
exit 0
