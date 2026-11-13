#!/bin/sh
# mk-icon.sh — compile the app icon, and record what it was compiled from.
#
# usage: mk-icon.sh            (needs Xcode: actool is not in the Command Line Tools)
#        mk-icon.sh --hash     prints the hash of the icon's source, and needs nothing
#
# The icon is an Icon Composer document, tools/build/AppIcon.icon (open it in Icon Composer to edit).
# This is the one way to change what ships: edit the document, run this, and commit the document together
# with tools/build/AppIcon-compiled. mk-app.sh copies the compiled files on a Mac without Xcode, and on
# one with Xcode refuses to build if they were not regenerated after the document changed.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
SOURCE="$HERE/AppIcon.icon"
OUT="$HERE/AppIcon-compiled"

# One hash over every file of the document, by name and content, in a fixed order.
source_hash() {
    (cd "$SOURCE" && find . -type f | LC_ALL=C sort | while IFS= read -r file; do shasum -a 256 "$file"; done) \
        | shasum -a 256 | cut -d' ' -f1
}

if [ "${1:-}" = "--hash" ]; then
    source_hash
    exit 0
fi

XCODE=/Applications/Xcode.app/Contents/Developer
[ -d "$XCODE" ] || { echo "mk-icon: Xcode is needed to compile the icon" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/openvm-icon.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
DEVELOPER_DIR=$XCODE xcrun actool "$SOURCE" --compile "$WORK" --platform macosx \
    --minimum-deployment-target 14.0 --app-icon AppIcon \
    --output-partial-info-plist "$WORK/icon.plist" >/dev/null
[ -f "$WORK/Assets.car" ] && [ -f "$WORK/AppIcon.icns" ] \
    || { echo "mk-icon: actool did not produce Assets.car and AppIcon.icns" >&2; exit 1; }

mkdir -p "$OUT"
cp "$WORK/Assets.car" "$WORK/AppIcon.icns" "$OUT/"
source_hash > "$OUT/source.sha256"
echo "mk-icon: wrote $OUT (source $(cat "$OUT/source.sha256"))"
