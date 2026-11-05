#!/bin/sh
# Guest audio handlers, against a fake /proc/asound. See test-audio-agent.c.
set -eu
cd "$(dirname "$0")/../.."
DIR=$(mktemp -d /tmp/openvm-audio-agent.XXXXXX)
trap 'rm -rf "$DIR"' EXIT
mkdir -p "$DIR/none" "$DIR/card/card0/pcm0p/sub0" "$DIR/bin"
echo VirtIOSound > "$DIR/card/card0/id"
printf 'state: RUNNING\nowner_pid   : 12\nhw_ptr      : 96000\nappl_ptr    : 100000\n' \
    > "$DIR/card/card0/pcm0p/sub0/status"
printf 'access: RW_INTERLEAVED\nrate: 48000 (48000/1)\n' > "$DIR/card/card0/pcm0p/sub0/hw_params"
printf '#!/bin/sh\nexit 0\n' > "$DIR/bin/speaker-test"
printf '#!/bin/sh\nexit 0\n' > "$DIR/bin/timeout"
chmod +x "$DIR/bin/"*
for tree in none card; do
    clang -std=c11 -Wall -Wextra -Werror -Wno-unused-function -I tools -DOPENVM_ASOUND="\"$DIR/$tree\"" -DOPENVM_AUDIO_LOG="\"/dev/null\"" \
        tools/test/test-audio-agent.c -o "$DIR/test-$tree"
done
PATH="$DIR/bin:$PATH" "$DIR/test-none" nocard
PATH="$DIR/bin:$PATH" "$DIR/test-card" card
