#!/bin/sh
# Fetch the UEFI headers we build our own firmware against.
#
# The headers are EDK2's MdePkg (the types and service tables) and
# MdeModulePkg (the protocol GUIDs), which are BSD-2-Clause licensed and so
# fine to build against. They are not vendored into the repository: this
# script pulls them into the support directory, the same place the Linux
# guest artifacts live.
#
# The GitHub API is not reachable from here, so the file list is discovered by
# following the #include lines instead of listing a directory.
set -eu

DEST="${1:-$HOME/openvm-support/uefi}"
EDK2="${EDK2_REF:-master}"
BASES="MdePkg/Include MdeModulePkg/Include"

mkdir -p "$DEST"
cd "$DEST"

# One file per path, the way the EDK2 tree is laid out, so that the includes
# resolve and the two base trees can coexist.
fetch_one() {
    base="$1"
    rel="$2"
    if [ -f "$DEST/$base/$rel" ]; then
        return 0
    fi
    mkdir -p "$DEST/$(dirname "$base/$rel")"
    if ! curl -fsSL "https://raw.githubusercontent.com/tianocore/edk2/$EDK2/$base/$rel" \
        -o "$DEST/$base/$rel.tmp" 2>/dev/null; then
        rm -f "$DEST/$base/$rel.tmp"
        return 1
    fi
    mv "$DEST/$base/$rel.tmp" "$DEST/$base/$rel"
    echo "  $base/$rel"
}

queue=""
for base in $BASES; do
    queue="$queue $base:Uefi.h $base:Base.h"
done
# The protocols we use live in MdePkg/Include/Protocol; they carry the GUIDs.
for proto in GraphicsOutput SimpleFileSystem LoadedImage BlockIo BlockIo2; do
    queue="$queue MdePkg/Include:Protocol/$proto.h"
done

seen=""
while [ -n "$queue" ]; do
    item=$(printf '%s\n' $queue | head -1)
    queue=$(printf '%s\n' $queue | tail -n +2)
    case " $seen " in
        *" $item "*) continue ;;
    esac
    seen="$seen $item"
    base=${item%%:*}
    rel=${item#*:}
    if ! fetch_one "$base" "$rel"; then
        # A seed that does not exist in this base tree is not fatal; the
        # include walk finds what is really there.
        continue
    fi
    # Follow the includes this file names. The EDK2 tree mixes plain names with
    # "Protocol/Name.h" style paths, and the architecture header
    # (ProcessorBind.h) lives in an arch directory that the build system puts
    # on the include path.
    dir=$(dirname "$rel")
    for inc in $(sed -n 's/^[[:space:]]*#[[:space:]]*include[[:space:]]*["<]\([^">]*\)[">].*/\1/p' "$DEST/$base/$rel"); do
        case "$inc" in
            */*) candidates="$inc" ;;
            *) candidates="$dir/$inc $inc AArch64/$inc Generic/$inc" ;;
        esac
        for sub in $candidates; do
            if curl -fsSL -o /dev/null "https://raw.githubusercontent.com/tianocore/edk2/$EDK2/$base/$sub" 2>/dev/null; then
                queue="$queue $base:$sub"
                break
            fi
        done
    done
done

echo "fetch-uefi-headers: $DEST now holds $(find "$DEST" -name '*.h' | wc -l | tr -d ' ') headers"
