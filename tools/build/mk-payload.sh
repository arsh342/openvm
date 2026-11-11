#!/bin/sh
# mk-payload.sh — assemble the guest payload: the files the host needs to build Windows install media, so a
# Mac with no developer tools can still make one.
#
#   usage: mk-payload.sh <out-dir>
#
#   <out-dir>/linux/openvm.apkovl.tar.gz   the overlay the helper VM boots with (its job script)
#   <out-dir>/linux/fetch-linux.sh         fetches the helper VM's pinned Alpine kernel, initramfs and modloop
#   <out-dir>/linux/openvm-zboot           unpacks the kernel; prebuilt, so the Mac needs no cc
#
#   <out-dir>/windows/mk-windows-media.sh  builds Windows install media from the user's ISO
#   <out-dir>/windows/wim-job.sh           the wimlib steps of that, run on the Mac or in a helper VM
#   <out-dir>/windows/scripts/             the Windows-side scripts and answer file
#   <out-dir>/windows/prebuilt/            the UEFI applications and the Windows agent, built here
#
# The Windows part needs clang, lld and zig to build, and is left out, with a note, where they are
# missing (CI, a contributor's Mac); the Linux part always builds.
# `make payload` puts it in .build/payload; `make app` puts it inside the app bundle.
set -eu

OUT=${1:?usage: mk-payload.sh <out-dir>}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

# mk-guest-overlay.sh uses paths relative to the repository root.
cd "$(dirname "$0")/../.."

rm -rf "$OUT/linux"
mkdir -p "$OUT/linux"

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
sh tools/build/mk-guest-overlay.sh "$stage" >/dev/null
mv "$stage/openvm.apkovl.tar.gz" "$OUT/linux/openvm.apkovl.tar.gz"

cc -O2 -o "$OUT/linux/openvm-zboot" tools/guest/openvm-zboot.c -lz
cp tools/build/fetch-linux.sh "$OUT/linux/fetch-linux.sh"
chmod 755 "$OUT/linux/openvm-zboot" "$OUT/linux/fetch-linux.sh"

# --- Windows ---------------------------------------------------------------------------------
uefi_headers=${UEFI_INCLUDE:-$HOME/openvm-support/uefi/MdePkg/Include}
lld=${LLD_LINK:-$(command -v lld-link || echo /opt/homebrew/opt/lld/bin/lld-link)}
rm -rf "$OUT/windows"
if command -v zig >/dev/null 2>&1 && command -v clang >/dev/null 2>&1 && [ -x "$lld" ] && [ -d "$uefi_headers" ]; then
    mkdir -p "$OUT/windows/scripts" "$OUT/windows/prebuilt/uefi" "$OUT/windows/prebuilt/agent"
    sh tools/build/build-uefi.sh >/dev/null
    cp .build/uefi/openvm-efi.efi .build/uefi/openvm-framebuffer.efi "$OUT/windows/prebuilt/uefi/"
    sh tools/build/build-windows-agent.sh "$stage/agent" >/dev/null
    cp "$stage/agent/openvm-tools-win.exe" "$OUT/windows/prebuilt/agent/"
    cp tools/windows/install.cmd tools/windows/SetupComplete.cmd tools/windows/unattend.xml \
        tools/windows/winpeshl.ini tools/windows/printers.ps1 tools/windows/sound.ps1 "$OUT/windows/scripts/"
    cp tools/build/mk-windows-media.sh tools/build/wim-job.sh "$OUT/windows/"
    chmod 755 "$OUT/windows/mk-windows-media.sh" "$OUT/windows/wim-job.sh"
else
    echo "mk-payload: no zig, clang, lld or UEFI headers here, so this payload cannot build Windows media" >&2
    echo "mk-payload:   (brew install zig lld; tools/build/fetch-uefi-headers.sh)" >&2
fi

echo "mk-payload: wrote $OUT"
