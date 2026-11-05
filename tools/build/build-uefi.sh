#!/bin/sh
# build-uefi.sh — build our UEFI applications for the Windows guest.
#
# The applications are PE32+ images (the format ARM64 UEFI uses) built with
# clang and the PE linker from lld. The EDK2 headers are fetched separately
# by tools/build/fetch-uefi-headers.sh; nothing is vendored into the repository.
set -e

UEFI_INCLUDE=${UEFI_INCLUDE:-$HOME/openvm-support/uefi/MdePkg/Include}
LLD_LINK=${LLD_LINK:-$(command -v lld-link || echo /opt/homebrew/opt/lld/bin/lld-link)}

if [ ! -d "$UEFI_INCLUDE" ]; then
    echo "build-uefi: no UEFI headers at $UEFI_INCLUDE; run tools/build/fetch-uefi-headers.sh" >&2
    exit 1
fi

build_one() {
    local SRC=$1
    local OUT=$2
    local EXTRA_DEFS=${3:-}
    # Drivers stay resident after their entry point returns; applications are
    # unloaded. The framebuffer driver installs hooks the boot manager calls
    # later, so it must be a boot-service driver.
    local SUBSYSTEM=${4:-efi_application}

    local OBJ="$(dirname "$OUT")/$(basename "$SRC" .c).obj"
    mkdir -p "$(dirname "$OUT")"

    clang --target=aarch64-windows-msvc -ffreestanding -fno-stack-protector -nostdlib -c \
        -I "$UEFI_INCLUDE" -I "$UEFI_INCLUDE/AArch64" -I "$UEFI_INCLUDE/Generic" \
        -I "$(dirname "$0")/../uefi" \
        ${EXTRA_DEFS} \
        -o "$OBJ" "$SRC"

    "$LLD_LINK" /Brepro /subsystem:$SUBSYSTEM /entry:EfiMain /nodefaultlib /out:"$OUT" "$OBJ"
    echo "build-uefi: wrote $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"
}

# Default: build both the chainloader and the framebuffer driver
build_one "tools/uefi/openvm-efi.c" ".build/uefi/openvm-efi.efi" "${EXTRA_DEFS:-}"
build_one "tools/uefi/openvm-framebuffer.c" ".build/uefi/openvm-framebuffer.efi" "" efi_boot_service_driver

# If arguments given, build only that one (for CI/targeted rebuilds)
if [ $# -ge 2 ]; then
    build_one "$2" "$1" "${EXTRA_DEFS:-}"
fi
