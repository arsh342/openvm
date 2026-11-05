#!/bin/sh
# install-efi-app.sh — put our UEFI application into the boot volume of a
# Windows boot disk.
#
# usage: install-efi-app.sh <disk.raw> <app.efi> [name-in-volume]
#
# The volume is found by CONTENT, not by partition number. macOS always lays
# out its own 200 MB EFI partition at s1 and refuses to skip it, so on a disk
# built by tools/build/mk-windows-media.sh the Windows payload lives on s2. Writing
# to s1 "succeeds" and then the firmware boots the Windows Boot Manager
# instead of our app — the run silently measures the wrong binary. The boot
# volume is the one that carries \EFI\Microsoft\Boot\bcd.
#
# The image must not be attached to the host while a guest uses it: the
# firmware rejects a storage attachment the host still holds.
set -e

IMG=${1:?usage: install-efi-app.sh <disk.raw> <app.efi> [name]}
APP=${2:?usage: install-efi-app.sh <disk.raw> <app.efi> [name]}
NAME=${3:-BOOT/BOOTAA64.EFI}

[ -f "$APP" ] || { echo "install-efi-app: no such app: $APP" >&2; exit 2; }

# The first line is the whole disk; the following lines are its partitions.
dev=$(diskutil image attach --noMount "$IMG" | head -1 | awk '{print $1}')
[ -b "$dev" ] || { echo "install-efi-app: could not attach $IMG" >&2; exit 1; }
bootvol=""
cleanup() {
    [ -n "$bootvol" ] && diskutil unmount "$bootvol" >/dev/null 2>&1 || true
    hdiutil detach "$dev" >/dev/null 2>&1 || true
    # A guest cannot use an image the host still holds, so wait for the
    # device to disappear before the caller boots it.
    i=0
    while [ -e "$dev" ] && [ $i -lt 50 ]; do
        sleep 0.2
        i=$((i + 1))
    done
}
trap cleanup EXIT

# Find every volume that could be the one the firmware boots. The old version
# looked only for \EFI\Microsoft\Boot\bcd and installed to that one volume.
# That is wrong for this media: the disk carries TWO volumes with
# \EFI\BOOT\BOOTAA64.EFI -- the ESP (s1) and the WINBOOT volume (s2, which also
# holds the BCD) -- and the firmware boots the ESP. The installer therefore
# wrote the new app to s2 and the guest kept running the stale app on s1, so a
# run silently measured the previous binary. Install to every candidate and
# verify each by hash instead of guessing which one the firmware picks.
#
# diskutil list prints bare identifiers ("disk4s2"), not "/dev/disk4s2".
bare=$(basename "$dev")
candidates=""
for part in $(diskutil list "$dev" | awk '/^ +[0-9]+:/{print $NF}' | grep -E "^${bare}s[0-9]+$"); do
    part="/dev/$part"
    diskutil mount "$part" >/dev/null 2>&1 || continue
    mp=$(diskutil info "$part" | sed -n 's/^ *Mount Point: *//p' | head -1)
    [ -n "$mp" ] || continue
    # A volume is a boot candidate if it already has a boot application at the
    # path we are about to write, or if it carries the BCD.
    if [ -f "$mp/EFI/$NAME" ] || [ -f "$mp/EFI/MICROSOFT/BOOT/bcd" ]; then
        candidates="$candidates $mp"
        echo "install-efi-app: candidate $part ($mp)"
    else
        diskutil unmount "$mp" >/dev/null 2>&1 || true
    fi
done

if [ -z "$candidates" ]; then
    diskutil mount "${dev}s1" >/dev/null 2>&1 || true
    fallback=$(diskutil info "${dev}s1" | sed -n 's/^ *Mount Point: *//p' | head -1)
    [ -n "$fallback" ] && candidates="$fallback"
    echo "install-efi-app: no boot candidate found; falling back to ${dev}s1" >&2
fi

want=$(shasum -a 256 "$APP" | awk '{print $1}')
installed=0
for bootvol in $candidates; do
    [ -d "$bootvol" ] || continue
    # A name may carry a subdirectory, e.g. "BOOT/BOOTAA64.EFI".
    dir=$(dirname "$NAME")
    mkdir -p "$bootvol/EFI/$dir"
    cp "$APP" "$bootvol/EFI/$NAME"
    got=$(shasum -a 256 "$bootvol/EFI/$NAME" | awk '{print $1}')
    if [ "$got" != "$want" ]; then
        echo "install-efi-app: VERIFY FAILED at $bootvol/EFI/$NAME" >&2
        echo "  want $want" >&2
        echo "  got  $got" >&2
        exit 1
    fi
    echo "install-efi-app: wrote $bootvol/EFI/$NAME"
    echo "install-efi-app: sha256 $got (verified)"
    installed=$((installed + 1))
done

[ "$installed" -gt 0 ] || { echo "install-efi-app: no usable boot volume" >&2; exit 1; }
echo "install-efi-app: installed to $installed volume(s)"
