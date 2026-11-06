#!/bin/sh
# mk-payload.sh — assemble the guest payload: the files the host needs to build a guest, so a
# Mac with no developer tools can still make one.
#
#   usage: mk-payload.sh <out-dir>
#
#   <out-dir>/linux/openvm.apkovl.tar.gz   the install overlay (installs Alpine, starts the agent)
#   <out-dir>/linux/fetch-linux.sh         fetches the pinned Alpine kernel, initramfs and modloop
#   <out-dir>/linux/openvm-zboot           unpacks the kernel; prebuilt, so the Mac needs no cc
#
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

echo "mk-payload: wrote $OUT"
