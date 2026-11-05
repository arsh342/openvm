#!/bin/sh
# Guest drag and drop handlers, against a real file tree. See test-drag-agent.c.
set -eu
cd "$(dirname "$0")/../.."
DIR=$(mktemp -d /tmp/openvm-drag-agent.XXXXXX)
trap 'rm -rf "$DIR"' EXIT
mkdir -p "$DIR/fs/drops/dtest/tree/sub" "$DIR/fs/drops/gone" "$DIR/run" "$DIR/home"
printf 'hello' > "$DIR/fs/drops/dtest/note.txt"
printf 'deepest' > "$DIR/fs/drops/dtest/tree/sub/deep.bin"
printf 'pdf' > "$DIR/fs/drops/dtest/Résumé final.pdf"
ln -s /etc/passwd "$DIR/fs/drops/dtest/tree/escape"
clang -std=c11 -Wall -Wextra -Werror -Wno-unused-function -I tools \
    -DOPENVM_FS_ROOT="\"$DIR/fs\"" -DOPENVM_RUN_USER="\"$DIR/run\"" \
    -DOPENVM_DROP_HOME="\"$DIR/home\"" -DOPENVM_DROP_NO_MOUNT \
    tools/test/test-drag-agent.c -o "$DIR/test"
"$DIR/test"
