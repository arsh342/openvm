#!/bin/sh
# Build a Windows-to-USB style raw disk image from a Windows installation ISO.
#
# Virtualization.framework attaches raw disk images, not ISO files, and its EFI
# firmware boots a disk the UEFI way: a FAT32 volume that carries
# \EFI\BOOT\BOOT<ARCH>.EFI.
#
# TWO VOLUMES, AND THE SPLIT IS NOT ARBITRARY.
#
# The BCD's device elements are volume-relative ("the volume this BCD lives
# on"), so everything a boot entry names has to sit on the same volume as the
# BCD:
#
#     \EFI\Microsoft\Boot\bcd          the store itself
#     \boot\boot.sdi                   the ramdisk's SDI container
#     \sources\boot.wim                the WinPE image the SDI carries
#
# That is the boot volume, and it must be FAT32 (the firmware's FAT driver is
# what reads it). FAT32 caps a file at 4 GiB. boot.wim is 638 MB, so it fits.
#
# install.wim is 7,617,008,767 bytes (7.6 GB) and CANNOT live on FAT32 at all.
# It is not named by any boot entry this milestone boots, so it goes on a
# second, exFAT volume where the 4 GiB limit does not apply. An earlier
# revision put boot.wim on the data volume instead, which broke the volume-
# relative lookup and made Windows Boot Manager fail with 0xc000000f
# (STATUS_NO_SUCH_DEVICE) before it ever opened the ramdisk.
#
# The image must be DETACHED from the host when the guest uses it: a disk that
# the host still claims is rejected with "The storage device attachment is
# invalid".
#
# usage: mk-windows-media.sh <windows-iso> <out-disk.raw> [boot-mb] [data-mb]
set -eu
# A cancelled build is stopped with SIGTERM. Without this the shell dies at once and its EXIT
# trap never runs, leaving the ISO and the 22 GB image attached.
trap 'exit 1' TERM INT HUP

ISO=${1:?usage: mk-windows-media.sh <windows-iso> <out-disk.raw> [boot-mb] [data-mb]}
OUT=${2:?usage: mk-windows-media.sh <windows-iso> <out-disk.raw> [boot-mb] [data-mb]}
# Boot volume: the ISO's efi/ + boot/ trees, boot.wim, and the BCD. ~1 GB is
# ample. The s1 ESP macOS forces is separate; mk-windows-media clears any
# stale boot application from it, because the firmware boots s1 first.
# 1536 MB: boot.wim grows by the WinPE payload (drivers, WinFsp, boot chain).
BOOT_MB=${3:-1536}
# Data volume: install.wim (7.6 GB) plus room for an in-place install.
DATA_MB=${4:-19456}

[ -f "$ISO" ] || { echo "no such iso: $ISO" >&2; exit 2; }

HERE=$(cd "$(dirname "$0")" && pwd)
# The Windows scripts, and the job script that does the wimlib steps. A checkout finds both next
# to this script; the app ships them in its payload and says where (OPENVM_WINDOWS_FILES).
SCRIPTS=${OPENVM_WINDOWS_FILES:-$HERE/../windows}
WIM_JOB=${OPENVM_WIM_JOB:-$HERE/wim-job.sh}
# The UEFI applications and the Windows agent. A checkout builds them (clang, lld and zig); the
# app ships them prebuilt (OPENVM_PREBUILT: uefi/*.efi and agent/openvm-tools-win.exe).
if [ -z "${OPENVM_PREBUILT:-}" ]; then
    sh "$HERE/build-uefi.sh" >/dev/null
    EFI_DIR=.build/uefi
else
    EFI_DIR="$OPENVM_PREBUILT/uefi"
fi

dev=""
cleanup() {
    [ -n "${isodev:-}" ] && hdiutil detach "$isodev" -quiet 2>/dev/null || true
    [ -n "$dev" ] && hdiutil detach "$dev" -quiet 2>/dev/null || true
    return 0
}
trap cleanup EXIT

# Attaches an image read-only and out of the Finder's sight, and prints the attach table. macOS 27
# deprecates hdiutil, and warns on every attach; older systems have no `diskutil image`.
attach_readonly() {
    if diskutil image attach --help >/dev/null 2>&1; then
        diskutil image attach --readOnly --nobrowse "$1"
    else
        hdiutil attach "$1" -nobrowse -readonly
    fi
}

mount_point() {
    diskutil info "$1" | sed -n 's/^ *Mount Point: *//p' | head -1
}

rm -f "$OUT"
diskutil image create blank --format RAW --size 22g --fs None "$OUT" >/dev/null
dev=$(diskutil image attach --noMount "$OUT" | head -1 | awk '{print $1}')
[ -b "$dev" ] || { echo "could not attach $OUT" >&2; exit 1; }

# macOS always lays out its own 200 MB EFI partition first (diskutil refuses to
# skip it), so our partitions are s2 and s3. Do not assume s1 is ours: that
# mistake writes the payload into the 200 MB partition and fails with ENOSPC.
#
diskutil partitionDisk "$dev" GPT MS-DOS WINBOOT "${BOOT_MB}m" ExFAT WINDATA "${DATA_MB}m" >/dev/null
bootvol=$(mount_point "${dev}s2")
datavol=$(mount_point "${dev}s3")
[ -d "$bootvol" ] || { echo "could not mount the boot volume at ${dev}s2" >&2; exit 1; }
[ -d "$datavol" ] || { echo "could not mount the data volume at ${dev}s3" >&2; exit 1; }

# The s1 ESP is macOS's, but it is NOT unused: the firmware scans volumes in
# order and boots the first one carrying \EFI\BOOT\BOOTAA64.EFI, which is s1.
# A stale application left there is what the guest actually runs, so a build
# installed only to s2 is never executed and a run silently measures the
# previous binary. Clear any boot application from s1 so the only one on the
# disk is the one install-efi-app.sh writes (which now covers every candidate
# volume and verifies each by hash).
espvol=$(mount_point "${dev}s1")
if [ -n "$espvol" ] && [ -d "$espvol/EFI/BOOT" ]; then
    rm -f "$espvol/EFI/BOOT/BOOTAA64.EFI"
    echo "mk-windows-media: cleared stale boot app from the s1 ESP ($espvol)"
fi

# The ISO's own layout: efi/ holds the boot managers, boot/ the setup files,
# sources/boot.wim the WinPE image the boot manager loads.
isoout=$(attach_readonly "$ISO" | tail -1)
isodev=$(echo "$isoout" | awk '{print $1}')
isomount=$(echo "$isoout" | awk -F'\t' '{print $NF}')  # tab-separated: the mount point may contain spaces
[ -d "$isomount" ] || { echo "could not mount $ISO" >&2; exit 1; }

# --- boot volume: everything the BCD names, on one FAT32 volume -------------
mkdir -p "$bootvol/EFI" "$bootvol/boot" "$bootvol/sources"
cp -R "$isomount/efi/." "$bootvol/EFI/"
cp -R "$isomount/boot/." "$bootvol/boot/"
# On the ARM64 media \EFI\BOOT\BOOTAA64.EFI *is* the Windows Boot Manager. Our
# UEFI application takes that path, so keep the boot manager under the standard
# Microsoft name for the application to chainload.
mkdir -p "$bootvol/EFI/MICROSOFT/BOOT"
cp "$isomount/efi/boot/bootaa64.efi" "$bootvol/EFI/MICROSOFT/BOOT/BOOTMGFW.EFI"
# --- Our UEFI boot chain on the media's boot volume -------------------------
# The firmware boots \EFI\BOOT\BOOTAA64.EFI; ours loads the framebuffer driver
# and then the media's own Boot Manager (EFI/MICROSOFT/BOOT/BOOTMGFW.EFI).
mkdir -p "$bootvol/EFI/BOOT"
cp "$EFI_DIR/openvm-efi.efi" "$bootvol/EFI/BOOT/BOOTAA64.EFI"
cp "$EFI_DIR/openvm-framebuffer.efi" "$bootvol/EFI/BOOT/OPENVM-FB.EFI"

# --- data volume: install.wim, which cannot live on FAT32 --------------------
mkdir -p "$datavol/sources" "$datavol/openvm"
cp "$isomount/sources/install.wim" "$datavol/sources/install.wim"
# install.cmd finds this volume by the tag, and writes its result and log here.
echo "openvm-install-media" > "$datavol/openvm/media.tag"

# --- virtio-win and WinFsp (cached; first download pinned by SHA-256) --------
# The wimlib steps run in a job script, on the Mac if it has wimlib-imagex (OPENVM_WIMLIB names it)
# or in a helper VM (OPENVM_WIM_EXEC is a program that runs `--wim-job <job-dir> <iso-root>`).
# The helper is chosen only when asked for: the caller picks the faster Mac copy when there is one.
if [ -z "${OPENVM_WIM_EXEC:-}" ]; then
    if [ -n "${OPENVM_WIMLIB:-}" ] && [ -x "$OPENVM_WIMLIB" ]; then
        WIM_PATH="$(dirname "$OPENVM_WIMLIB"):$PATH"
    elif command -v wimlib-imagex >/dev/null 2>&1; then
        WIM_PATH="$PATH"
    else
        echo "mk-windows-media: needs wimlib-imagex on this Mac (brew install wimlib), or a helper VM (OPENVM_WIM_EXEC)" >&2
        exit 1
    fi
fi
# The downloads are about 900 MB, so the cache stays put whatever throwaway home a test runs in.
CACHE="${OPENVM_CACHE:-$HOME/.openvm/cache}"
VIRTIO_ISO="${OPENVM_VIRTIO_ISO:-$CACHE/virtio-win/virtio-win.iso}"
VIRTIO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
WINFSP_VERSION="2.1.25156"
WINFSP_MSI="${OPENVM_WINFSP_MSI:-$CACHE/winfsp/winfsp-$WINFSP_VERSION.msi}"
WINFSP_URL="https://github.com/winfsp/winfsp/releases/download/v2.1/winfsp-$WINFSP_VERSION.msi"
fetch_pinned() { # $1 = local file, $2 = url
    mkdir -p "$(dirname "$1")"
    if [ ! -s "$1" ]; then
        echo "mk-windows-media: downloading $2"
        curl -fL --retry 2 -o "$1.tmp" "$2" && mv "$1.tmp" "$1"
    fi
    sum=$(shasum -a 256 "$1" | awk '{print $1}')
    if [ -f "$1.sha256" ]; then
        [ "$sum" = "$(cat "$1.sha256")" ] || { echo "mk-windows-media: $1 does not match its pinned SHA-256" >&2; exit 1; }
    else
        echo "$sum" > "$1.sha256"
    fi
}
fetch_pinned "$VIRTIO_ISO" "$VIRTIO_URL"
fetch_pinned "$WINFSP_MSI" "$WINFSP_URL"

# --- WinPE payload: X:\openvm inside boot.wim --------------------------------
# WinPE runs tools/windows/install.cmd instead of Setup (winpeshl.ini). Every
# input it needs travels inside the RAM disk, so the script depends on the media
# volume only for install.wim and for recording its result.
work=$(mktemp -d)
job="$work/job"
pe="$job/pe"
mkdir -p "$pe/drivers" "$pe/efi" "$pe/payload/virtiofs"
virtio_out=$(attach_readonly "$VIRTIO_ISO" | tail -1)
virtio_dev=$(echo "$virtio_out" | awk '{print $1}')
virtio_mount=$(echo "$virtio_out" | awk -F'\t' '{print $NF}')
# OPENVM_WIN_DRIVERS overrides the set (viostor is required: without it the
# installed system cannot see its own disk).
# viogpudo is the virtio-gpu display driver: dynamic resolution needs it, because
# Windows' basic display is stuck with the boot framebuffer's mode.
for driver in ${OPENVM_WIN_DRIVERS:-viostor NetKVM viosock viofs Balloon vioinput viogpudo}; do
    src="$virtio_mount/$driver/w11/ARM64"
    [ -d "$src" ] || { echo "mk-windows-media: virtio-win has no ARM64 $driver" >&2; exit 1; }
    mkdir -p "$pe/drivers/$driver"
    # The whole driver package minus debug symbols: an INF can name helper
    # executables (NetKVM's netkvmco/netkvmp, viosock's viosockwspsvc), and DISM
    # refuses the package with error 2 if any of them is missing.
    for f in "$src"/*; do
        case "$f" in *.pdb) continue ;; esac
        [ -f "$f" ] && cp "$f" "$pe/drivers/$driver/"
    done
done
cp "$virtio_mount/viofs/w11/ARM64/virtiofs.exe" "$pe/payload/virtiofs/virtiofs.exe"
hdiutil detach "$virtio_dev" -quiet
cp "$WINFSP_MSI" "$pe/payload/WinFsp.msi"
# The guest agent (tools/guest/openvm-tools-win.c), installed as the
# OpenVMTools service by SetupComplete.cmd.
if [ -n "${OPENVM_PREBUILT:-}" ]; then
    agent="$OPENVM_PREBUILT/agent/openvm-tools-win.exe"
else
    sh "$HERE/build-windows-agent.sh" "$work/agent" >/dev/null
    agent="$work/agent/openvm-tools-win.exe"
fi
cp "$agent" "$pe/payload/openvm-tools-win.exe"
cp "$SCRIPTS/printers.ps1" "$pe/payload/printers.ps1"
# Sound stays off until `openvmctl audio enable`, which installs this test-signed
# driver (docs/windows-guests.md). The release is a moving prerelease, so the
# file is pinned here, and a guest without it just cannot turn sound on.
SOUND_ZIP="${OPENVM_WIN_SOUND_ZIP:-$CACHE/viosnd/gunyah-arm64-drivers.zip}"
SOUND_URL="https://github.com/Droid-VM/gunyah-guest-drivers-windows/releases/download/dev/gunyah-arm64-drivers.zip"
SOUND_SHA256="207d566ca39894eee7a811a1ff92e6e8826260a810e337c3bb88b1bec908d716"
mkdir -p "$(dirname "$SOUND_ZIP")"
if [ ! -s "$SOUND_ZIP" ] && curl -fL --retry 2 -o "$SOUND_ZIP.tmp" "$SOUND_URL"; then
    mv "$SOUND_ZIP.tmp" "$SOUND_ZIP"
fi
if [ -s "$SOUND_ZIP" ] && [ "$(shasum -a 256 "$SOUND_ZIP" | awk '{print $1}')" = "$SOUND_SHA256" ]; then
    mkdir -p "$pe/payload/sound"
    unzip -q -j -o "$SOUND_ZIP" 'DroidVM_Test.cer' 'drivers/viosnd/*' -d "$pe/payload/sound"
    cp "$SCRIPTS/sound.ps1" "$pe/payload/sound/sound.ps1"
else
    echo "mk-windows-media: WARNING no pinned sound driver, so this media cannot turn Windows sound on" >&2
fi
cp "$EFI_DIR/openvm-efi.efi" "$pe/efi/BOOTAA64.EFI"
cp "$EFI_DIR/openvm-framebuffer.efi" "$pe/efi/OPENVM-FB.EFI"
# cmd wants CRLF; labels and goto misbehave on bare LF.
sed 's/$/\r/' "$SCRIPTS/install.cmd" > "$pe/install.cmd"
# The account. A caller that sets these has already escaped them (WindowsAccount.templateValue).
WIN_USER=${OPENVM_WIN_USER:-openvm}
WIN_PASSWORD=${OPENVM_WIN_PASSWORD:-openvm}
LC_ALL=C sed -e "s|@USER@|$WIN_USER|g" -e 's/$/\r/' "$SCRIPTS/SetupComplete.cmd" > "$pe/SetupComplete.cmd"
# --- the wimlib steps ---------------------------------------------------------
# Reading install.wim for the edition and language, and adding the payload to boot.wim, are done by
# one script (wim-job.sh) that needs wimlib: run here if the Mac has it, otherwise in a helper VM
# that gets wimlib from Alpine. Its inputs are staged in $job; the ISO is shared read-only.
if [ "${OPENVM_WIN_AUTOLOGON:-1}" = 0 ]; then
    no_logon='/@AUTOLOGON-BEGIN@/,/@AUTOLOGON-END@/d'
else
    no_logon='/@AUTOLOGON-/d'
fi
# @PASSWORD@ goes in last, so a password that spells a marker stays a password.
LC_ALL=C sed -e "$no_logon" -e "s|@USER@|$WIN_USER|g" -e "s|@PASSWORD@|$WIN_PASSWORD|g" \
    "$SCRIPTS/unattend.xml" > "$job/unattend.xml.in"
cp "$SCRIPTS/winpeshl.ini" "$job/winpeshl.ini"
cp "$WIM_JOB" "$job/job.sh"
if [ -n "${OPENVM_WIM_EXEC:-}" ]; then
    echo "mk-windows-media: building boot.wim in a helper VM"
    "$OPENVM_WIM_EXEC" --wim-job "$job" "$isomount" || { echo "mk-windows-media: the helper VM job failed" >&2; exit 1; }
else
    echo "mk-windows-media: building boot.wim with wimlib on this Mac"
    PATH="$WIM_PATH" sh "$job/job.sh" "$isomount" "$job" || { echo "mk-windows-media: the wimlib job failed" >&2; exit 1; }
fi
[ -f "$job/boot.wim" ] && [ -f "$job/result" ] || { echo "mk-windows-media: the job left no boot.wim" >&2; exit 1; }
# The ramdisk image goes beside the BCD that names it: the BCD's device elements
# are volume-relative, so \boot\boot.sdi and \sources\boot.wim share its volume.
cp "$job/boot.wim" "$bootvol/sources/boot.wim"
read -r image_index image_lang < "$job/result"
rm -rf "$work"
echo "mk-windows-media: WinPE runs install.cmd (image $image_index, $image_lang)"

sync
hdiutil detach "$isodev" -quiet
isodev=""

echo "mk-windows-media: wrote $OUT"
echo "mk-windows-media: boot volume (${dev}s2, FAT32):"
for f in "EFI/MICROSOFT/BOOT/bcd" "boot/boot.sdi" "sources/boot.wim"; do
    if [ -f "$bootvol/$f" ]; then
        echo "mk-windows-media:   $f ($(wc -c < "$bootvol/$f" | tr -d ' ') bytes)"
    else
        echo "mk-windows-media:   MISSING $f" >&2
    fi
done
echo "mk-windows-media: data volume (${dev}s3, exFAT):"
for f in "sources/install.wim" "openvm/media.tag"; do
    if [ -f "$datavol/$f" ]; then
        echo "mk-windows-media:   $f ($(wc -c < "$datavol/$f" | tr -d ' ') bytes)"
    else
        echo "mk-windows-media:   MISSING $f" >&2
    fi
done
diskutil unmount "${dev}s2" >/dev/null 2>&1 || true
diskutil unmount "${dev}s3" >/dev/null 2>&1 || true
hdiutil detach "$dev" -quiet
dev=""
trap - EXIT
