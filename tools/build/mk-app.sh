#!/bin/sh
# mk-app.sh — assemble .build/openvm.app from the SwiftPM build.
#
# usage: mk-app.sh [debug|release]      (default: debug)
# env:   OPENVM_SIGN_IDENTITY           codesign identity (default "-", ad hoc)
#
# SwiftPM builds the executable; this wraps it in a bundle and signs it with the
# Virtualization entitlement, because the app boots VMs itself. The bundle needs no
# privileges: no helper, no setuid file, no App Sandbox.
set -eu

CONFIG=${1:-debug}
case "$CONFIG" in debug | release) ;; *) echo "usage: mk-app.sh [debug|release]" >&2; exit 2 ;; esac

swift build -c "$CONFIG" --product openvm
BIN="$(swift build -c "$CONFIG" --show-bin-path)/openvm"
[ -x "$BIN" ] || { echo "mk-app: no executable at $BIN" >&2; exit 1; }

APP=.build/openvm.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/openvm"
cp "$(dirname "$0")/Info.plist" "$APP/Contents/Info.plist"

# The icon is an Icon Composer document (tools/build/AppIcon.icon; open it in Icon Composer to edit).
# actool ships with Xcode, not the Command Line Tools: without it the app is built with no icon.
XCODE=/Applications/Xcode.app/Contents/Developer
if [ -d "$XCODE" ]; then
    DEVELOPER_DIR=$XCODE xcrun actool "$(dirname "$0")/AppIcon.icon" --compile "$APP/Contents/Resources" \
        --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
        --output-partial-info-plist "${TMPDIR:-/tmp}/openvm-icon.plist" >/dev/null \
        || echo "mk-app: the icon did not compile; continuing without it" >&2
else
    echo "mk-app: Xcode not found; building without the icon" >&2
fi

# The guest payload goes in before signing: the signature seals the bundle's resources.
sh "$(dirname "$0")/mk-payload.sh" "$APP/Contents/Resources/guest" >/dev/null

codesign --force --sign "${OPENVM_SIGN_IDENTITY:--}" \
    --entitlements "$(dirname "$0")/vm.entitlements.xml" --options runtime "$APP" >/dev/null 2>&1 \
    || { echo "mk-app: signing failed" >&2; exit 1; }

echo "mk-app: wrote $APP"
