#!/bin/sh
# Fetch the alpine ARM64 netboot kernel, initramfs and modloop for bootloader-free direct kernel boot
# (VZLinuxBootLoader: the guest's bootloaders only matter for ISO/disk boots, not here).
# Verifies content against a pinned SHA-256 manifest created on the first run;
# later runs fail fast if the artifacts were corrupted or swapped.
# Env: OPENVM_SUPPORT (default ~/openvm-support), ALPINE_VER (default 3.22).
set -eu

VER="${ALPINE_VER:-3.22}"
DEST="${OPENVM_SUPPORT:-$HOME/openvm-support}/linux-arm64"
MIR1="https://dl-cdn.alpinelinux.org"
MIR2="https://uk.alpinelinux.org"
PATHPAIR="alpine/v$VER/releases/aarch64/netboot"
mkdir -p "$DEST"
MANIFEST="$DEST/SHA256SUMS"

fail() { echo "fetch-linux: FAIL $1" >&2; exit 1; }

get() { # $1 = local file, $2 = remote file name
  for m in "$MIR1" "$MIR2"; do
    if curl -fL --retry 2 -o "$1.tmp" "$m/$PATHPAIR/$2"; then
      mv "$1.tmp" "$1" && return 0
    fi
  done
  fail "could not download $2 from any mirror"
}

get "$DEST/vmlinuz.tmp" "vmlinuz-virt"
get "$DEST/initrd.gz.tmp" "initramfs-virt"
# The kernel's modules. They must match it exactly, and the mirror replaces them
# with every kernel update, so they are pinned here and openvmd serves this copy.
get "$DEST/modloop-virt.tmp" "modloop-virt"

# Alpine ships vmlinuz-virt as an EFI zboot container ("MZ"+"zimg", gzip payload).
# VZLinuxBootLoader needs the raw arm64 Image, so unpack it and verify the internal
# arm64 magic ("ARMd64" lives at offset 0x38 of a raw kernel image).
zboot="$DEST/openvm-zboot.tmp"
cc -O2 -o "$zboot" "$(dirname "$0")/../guest/openvm-zboot.c" -lz || exit 1
status=0
"$zboot" "$DEST/vmlinuz.tmp" "$DEST/vmlinuz.raw.tmp" || status=$?
rm -f "$zboot"
case "$status" in
  0) mv "$DEST/vmlinuz.raw.tmp" "$DEST/vmlinuz.tmp" ;;
  3) ;; # already a raw image
  *) exit 1 ;;
esac

# Rename into the consumer contract only after both downloads succeeded.
mv "$DEST/vmlinuz.tmp" "$DEST/vmlinuz"
mv "$DEST/initrd.gz.tmp" "$DEST/initrd.gz"
mv "$DEST/modloop-virt.tmp" "$DEST/modloop-virt"

NEWV=$( (cd "$DEST" && shasum -a 256 vmlinuz initrd.gz modloop-virt) )
# A manifest from before the modloop was pinned: the same kernel and initramfs
# mean this modloop belongs with them, so it joins the manifest.
if [ -f "$MANIFEST" ] && ! grep -q modloop-virt "$MANIFEST" &&
   [ "$(cat "$MANIFEST")" = "$(echo "$NEWV" | grep -v modloop-virt)" ]; then
  printf '%s' "$NEWV" > "$MANIFEST"
  echo "fetch-linux: modloop added to the pinned manifest"
fi
if [ -f "$MANIFEST" ]; then
  PINNED=$(cat "$MANIFEST")
  if [ "${PINNED}" != "${NEWV}" ]; then
    fail "checksum mismatch against pinned $MANIFEST
pinned: ${PINNED}
actual: ${NEWV}
If alpine shipped new artifacts intentionally: rm $MANIFEST and re-run."
  fi
else
  printf '%s' "$NEWV" > "$MANIFEST"
  echo "fetch-linux: pinned manifest created ($MANIFEST)"
fi

ls -l "$DEST/vmlinuz" "$DEST/initrd.gz" "$DEST/modloop-virt"
echo "fetch-linux: okay (v$VER $MIR1)"
