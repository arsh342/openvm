#!/bin/sh
# Guest printing handlers, against fake CUPS tools. See test-printer-agent.c.
set -eu
cd "$(dirname "$0")/../.."
DIR=$(mktemp -d /tmp/openvm-printer-agent.XXXXXX)
trap 'rm -rf "$DIR"' EXIT
mkdir -p "$DIR/bin" "$DIR/spool"
for tool in lpadmin lp; do
    cat > "$DIR/bin/$tool" <<FAKE
#!/bin/sh
echo "$tool \$*" >> "\$OVM_TEST_CALLS"
FAKE
done
cat > "$DIR/bin/lpstat" <<'FAKE'
#!/bin/sh
echo "device for OfficeLaser: ipp://printer.local/ipp/print"
echo "device for Stale: openvm:/Stale"
FAKE
chmod +x "$DIR/bin/"*
clang -std=c11 -Wall -Wextra -Werror -Wno-unused-function -I tools \
    -DOPENVM_PRINT_SPOOL="\"$DIR/spool\"" -DOPENVM_PRINT_PPD="\"/ppd\"" \
    tools/test/test-printer-agent.c -o "$DIR/test"
PATH="$DIR/bin:$PATH" OVM_TEST_CALLS="$DIR/calls" "$DIR/test"
