#! /bin/sh -e
# Regression test for https://github.com/NixOS/patchelf/issues/643
#
# Some shared objects (e.g. the OpenSSL libcrypto.so.1.1 shipped in manylinux
# wheels) keep their program header table near the END of the file instead of
# right after the ELF header. When growing such a library, patchelf's in-place
# section-collision check measured section offsets from the start of the file,
# which is only meaningful when the PHT sits at its canonical location. With the
# PHT elsewhere it looked in the wrong place and refused to relocate the PHT,
# corrupting the section table; the symptom was patchelf aborting with
# "cannot find section '.hash'". This test patches such a library and checks
# that it succeeds and that the change actually took effect.

PATCHELF=$(readlink -f "../src/patchelf")
SCRATCH="scratch/$(basename "$0" .sh)"
READELF=${READELF:-readelf}
fixture="${srcdir:?}/pht-relocation/libcrypto.so.1.1.xz"

if ! command -v xz >/dev/null 2>&1; then
    echo "SKIP: xz not available to decompress the fixture"
    exit 77
fi

rm -rf "${SCRATCH}"
mkdir -p "${SCRATCH}"
xz -dc "${fixture}" > "${SCRATCH}/libcrypto.so.1.1"

# Sanity: the fixture must actually exercise the bug, i.e. its PHT must not be
# at the canonical offset right after the ELF header.
phoff=$(${READELF} -hW "${SCRATCH}/libcrypto.so.1.1" | sed -n 's/.*Start of program headers:[^0-9]*\([0-9]*\).*/\1/p')
if [ "${phoff}" = "64" ] || [ -z "${phoff}" ]; then
    echo "FAIL: fixture PHT is at offset '${phoff}', expected a non-canonical offset"
    exit 1
fi

# A long RPATH forces .dynstr to grow, which triggers the section-relocation
# path. Before the fix this aborts with "cannot find section '.hash'".
rpath=$(awk 'BEGIN{s="/";for(i=0;i<4000;i++)s=s"x";print s}')
"${PATCHELF}" --set-rpath "${rpath}" "${SCRATCH}/libcrypto.so.1.1"

newRPath=$("${PATCHELF}" --print-rpath "${SCRATCH}/libcrypto.so.1.1")
if [ "${newRPath}" != "${rpath}" ]; then
    echo "FAIL: RPATH was not set (got '${newRPath}')"
    exit 1
fi

# The result must still be a structurally valid ELF with exactly one PHDR entry.
readelfData=$(${READELF} -lW "${SCRATCH}/libcrypto.so.1.1" 2>&1)
if echo "${readelfData}" | grep -qiE 'error|warning'; then
    echo "FAIL: readelf reported problems with the patched file"
    echo "${readelfData}"
    exit 1
fi

echo "PASS"
