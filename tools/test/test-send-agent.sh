#!/bin/sh
# The guest's send tool, against a real file tree: what it sends, and what it refuses. See
# tools/guest/openvm-send.c.
set -eu
cd "$(dirname "$0")/../.."
DIR=$(mktemp -d /tmp/openvm-send-agent.XXXXXX)
trap 'rm -rf "$DIR"' EXIT
clang -std=c11 -Wall -Wextra -Werror -D_DARWIN_C_SOURCE tools/guest/openvm-send.c -o "$DIR/send"
SEND="$DIR/send"
fail() { echo "test-send-agent: FAIL: $*" >&2; exit 1; }

mkdir -p "$DIR/out" "$DIR/src/tree/sub"
printf 'hello' > "$DIR/src/note.txt"
printf 'deepest' > "$DIR/src/tree/sub/deep.bin"

# A good send: one file and one tree, left as a finished set with its list.
"$SEND" -o "$DIR/out" "$DIR/src/note.txt" "$DIR/src/tree/" >/dev/null || fail "good send refused"
set_dir=$(find "$DIR/out" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | head -1)
[ -n "$set_dir" ] || fail "no finished set appeared"
[ "$(cat "$set_dir/note.txt")" = hello ] || fail "file content changed"
[ "$(cat "$set_dir/tree/sub/deep.bin")" = deepest ] || fail "nested content changed"
[ "$(cat "$set_dir/.ready")" = "$(printf 'note.txt\ntree')" ] || fail "manifest wrong: $(cat "$set_dir/.ready")"
[ -z "$(find "$DIR/out" -maxdepth 1 -name '.incoming-*')" ] || fail "hidden set left behind"
rm -rf "$DIR/out"; mkdir "$DIR/out"

# A link anywhere stops the whole send, and leaves nothing.
ln -s /etc/passwd "$DIR/src/tree/escape"
if "$SEND" -o "$DIR/out" "$DIR/src/tree" 2>/dev/null; then fail "a link was sent"; fi
[ -z "$(ls -A "$DIR/out")" ] || fail "a refused send left files: $(ls -A "$DIR/out")"
rm "$DIR/src/tree/escape"

# A link given directly is refused too.
ln -s "$DIR/src/note.txt" "$DIR/src/linked.txt"
if "$SEND" -o "$DIR/out" "$DIR/src/linked.txt" 2>/dev/null; then fail "a top-level link was sent"; fi
[ -z "$(ls -A "$DIR/out")" ] || fail "link refusal left files"

# A fifo is refused, and does not hang the tool.
mkfifo "$DIR/src/pipe"
if "$SEND" -o "$DIR/out" "$DIR/src/pipe" 2>/dev/null; then fail "a pipe was sent"; fi

# Names: duplicates, the manifest's own name, and a name with a newline.
mkdir -p "$DIR/other"; printf 'x' > "$DIR/other/note.txt"
if "$SEND" -o "$DIR/out" "$DIR/src/note.txt" "$DIR/other/note.txt" 2>/dev/null; then fail "duplicate names sent"; fi
printf 'x' > "$DIR/src/.ready"
if "$SEND" -o "$DIR/out" "$DIR/src/.ready" 2>/dev/null; then fail ".ready was sent"; fi
nl=$(printf 'a\nb'); printf 'x' > "$DIR/src/$nl"
if "$SEND" -o "$DIR/out" "$DIR/src/$nl" 2>/dev/null; then fail "a newline name was sent"; fi

# Missing files, no arguments, an unusable outbox.
if "$SEND" -o "$DIR/out" "$DIR/src/ghost" 2>/dev/null; then fail "a missing file was sent"; fi
if "$SEND" -o "$DIR/out" 2>/dev/null; then fail "an empty send was accepted"; fi
if "$SEND" -o "$DIR/nowhere" "$DIR/src/note.txt" 2>/dev/null; then fail "a missing outbox was accepted"; fi
[ -z "$(ls -A "$DIR/out")" ] || fail "refusals left files: $(ls -A "$DIR/out")"

# A big file arrives whole.
head -c 20000000 /dev/urandom > "$DIR/src/big.bin"
"$SEND" -o "$DIR/out" "$DIR/src/big.bin" >/dev/null || fail "big send refused"
set_dir=$(find "$DIR/out" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | head -1)
cmp -s "$DIR/src/big.bin" "$set_dir/big.bin" || fail "big file differs"
echo "test-send-agent: checks passed"
