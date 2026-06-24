#!/bin/bash
# Diagnostic for NixOS/patchelf#639. We know the fix is in DT_INIT/DT_FINI
# fixup; the hard part is producing an input where --set-rpath actually
# relocates .init. This run dumps patchelf's own decision (PATCHELF_DEBUG=1)
# plus full before/after layouts so we can see when/whether .init moves.
#
# Usage: verify.sh <patchelf-FIXED> <patchelf-CONTROL>
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
int main(int argc, char **argv){ void*h=dlopen(argv[1],RTLD_NOW);
  if(!h){fprintf(stderr,"dlopen FAILED: %s\n",dlerror());return 2;} return 0; }
EOF
cc -O2 -o "$work/dlopen" "$work/dlopen.c" -ldl

init_shaddr() { readelf -SW "$1" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i==".init") print $(i+2)}'; }
dt_init()     { readelf -dW "$1" 2>/dev/null | awk '/\(INIT\)/{print $NF}'; }
dlopen_rc()   { cp "$1" "$work/cur.so"; ( cd "$work" && ./dlopen "$work/cur.so" ); echo $?; }

diagnose() { # $1=name $2=lib
    local name="$1" lib="$2"
    echo "########################################################"
    echo "## CONFIG: $name"
    echo "########################################################"
    echo "---- BEFORE: program headers + low sections ----"
    readelf -lW "$lib" 2>&1 | sed -n '1,40p'
    readelf -SW "$lib" 2>&1 | awk 'NR<=5 || /\.(init|plt|text|note|dynstr|dynsym|gnu\.hash|hash|dynamic)\b/'
    local sh0 dt0; sh0="$(init_shaddr "$lib")"; dt0="$(dt_init "$lib")"

    cp "$lib" "$work/$name.fixed.so"
    echo "---- PATCHELF_DEBUG (FIXED) --set-rpath (very long) ----"
    PATCHELF_DEBUG=1 "$PE_FIXED" --set-rpath "\$ORIGIN/$(head -c 9000 /dev/zero | tr '\0' x)" "$work/$name.fixed.so" 2>&1 | grep -iE 'init|fini|reloc|phdr|segment|moving|shifting|adding|grow' | sed -n '1,40p'

    cp "$lib" "$work/$name.ctrl.so"
    "$PE_CTRL" --set-rpath "\$ORIGIN/$(head -c 9000 /dev/zero | tr '\0' x)" "$work/$name.ctrl.so" 2>/dev/null || true

    local shF dtF shC dtC; shF="$(init_shaddr "$work/$name.fixed.so")"; dtF="$(dt_init "$work/$name.fixed.so")"
    shC="$(init_shaddr "$work/$name.ctrl.so")"; dtC="$(dt_init "$work/$name.ctrl.so")"
    echo "---- AFTER (FIXED): .init section + program headers ----"
    readelf -SW "$work/$name.fixed.so" 2>&1 | awk '/\.init\b/'
    readelf -lW "$work/$name.fixed.so" 2>&1 | sed -n '1,12p'

    local moved=no; [ -n "$shF" ] && [ "$sh0" != "$shF" ] && moved=YES
    echo "==> .init: orig=$sh0 fixed=$shF ctrl=$shC  (relocated=$moved)"
    echo "==> DT_INIT: orig=$dt0 fixed=$dtF ctrl=$dtC"
    echo "==> dlopen rc: fixed=$(dlopen_rc "$work/$name.fixed.so") ctrl=$(dlopen_rc "$work/$name.ctrl.so")  (0=ok 139=SIGSEGV)"
    echo
}

clang -fuse-ld=lld -shared -fPIC -O2 -Wl,--build-id=sha1 -o "$work/default.so" "$work/foo.c"
diagnose "default" "$work/default.so"

clang -fuse-ld=lld -shared -fPIC -O2 -Wl,--build-id=sha1 -Wl,--section-start=.init=0x300 -o "$work/init300.so" "$work/foo.c"
diagnose "init300" "$work/init300.so"

echo "DIAGNOSTIC RUN COMPLETE"
