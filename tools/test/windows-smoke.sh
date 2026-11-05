#!/bin/sh
# End-to-end smoke test on a real Windows guest: installs Windows through openvmd in
# a throwaway OPENVM_HOME, exercises every integration feature, then reads the guest's
# disk. Takes about 30 minutes and about 40 GB. It plays a tone, and it replaces the
# Mac's clipboard while it runs, restoring plain text afterwards.
#
# usage: windows-smoke.sh <windows-iso>
#   OPENVM_WIN_MEDIA=<raw>   use media already built by mk-windows-media.sh
#   OPENVM_WIN_SETTLE=<s>    wait for first-boot setup to finish (default 480)
#   OPENVM_SMOKE_KEEP=1      keep the VM and logs
# Exit 0 = all assertions pass. Assumes `swift build` has already succeeded.
set -u

cd "$(dirname "$0")/../.." || exit 1
ISO=${1:-}
MEDIA=${OPENVM_WIN_MEDIA:-}
[ -n "$ISO" ] || [ -n "$MEDIA" ] || { echo "usage: windows-smoke.sh <windows-iso>" >&2; exit 2; }
SETTLE=${OPENVM_WIN_SETTLE:-480}
DAEMON=.build/debug/openvmd
CTL=.build/debug/openvmctl
HOME_DIR=$(mktemp -d /tmp/openvm-winsmoke.XXXXXX)
export OPENVM_HOME="$HOME_DIR"
SAVED_CLIPBOARD=$(pbpaste)
VM=win
PID=""
MOUNT_DEV=""

cleanup() {
  [ -n "$MOUNT_DEV" ] && hdiutil detach "$MOUNT_DEV" -quiet
  if [ -n "$PID" ]; then
    "$CTL" stop "$VM" >/dev/null 2>&1
    kill "$PID" 2>/dev/null
    wait "$PID" 2>/dev/null
  fi
  printf '%s' "$SAVED_CLIPBOARD" | pbcopy
  if [ "${OPENVM_SMOKE_KEEP:-0}" = 1 ]; then
    echo "smoke: artifacts retained at $HOME_DIR" >&2
  else
    rm -rf "$HOME_DIR"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

fail() {
  echo "smoke: FAIL $1" >&2
  exit 1
}

# Retries $2 until it succeeds: $1 attempts, 5 s apart.
retry() {
  tries=$1
  shift
  while [ "$tries" -gt 0 ]; do
    "$@" && return 0
    tries=$((tries - 1))
    sleep 5
  done
  return 1
}

queue_listed() { "$CTL" printer list "$VM" 2>/dev/null | grep -q "^$1\$"; }
queue_gone() { ! "$CTL" printer list "$VM" 2>/dev/null | grep -q "^$1\$"; }
pdf_count_is() { [ "$(find "$HOME_DIR/printed" -name '*.pdf' | wc -l | tr -d ' ')" = "$1" ]; }
agent_up() { "$CTL" ping "$VM" >/dev/null 2>&1; }

clipboard_round_trip() {
  text="openvm clipboard héllo ✓ $1 $RANDOM"
  printf '%s' "$text" | pbcopy
  retry 24 sh -c "'$CTL' clipboard push $VM 2>/dev/null | grep -q 'copied to guest'" \
    || fail "clipboard push failed ($1)"
  printf 'overwritten' | pbcopy
  "$CTL" clipboard pull "$VM" | grep -q 'copied to host' || fail "clipboard pull failed ($1)"
  [ "$(pbpaste)" = "$text" ] || fail "clipboard round trip mismatch ($1): $(pbpaste)"
}

restart_guest() {
  "$CTL" stop "$VM" | grep -q "stopped $VM" || fail "stop failed"
  [ -n "${1:-}" ] && { "$CTL" set "$VM" --tz "$1" >/dev/null || fail "set --tz failed"; }
  "$CTL" start "$VM" >/dev/null || fail "start failed"
  retry 36 agent_up || fail "the agent did not come back after a restart"
}

# HiDPI: the guest scales its desktop at a size that leaves room for it.
scale_test() {
  "$CTL" display set "$1" --width "$2" --height "$3" --scale "$4" \
    | grep -q "display is $2x$3 at $4x" || fail "guest did not take $2x$3 at $4x"
  sleep 3
  capture=$("$CTL" display capture "$1") || fail "capture at $4x failed"
  "$CTL" file pull "$1" "$capture" "$HOME_DIR/scale-$4.$5" >/dev/null || fail "capture pull failed"
  [ "$(sips -g pixelWidth "$HOME_DIR/scale-$4.$5" | awk '/pixelWidth/{print $2}')" = "$2" ] \
    || fail "capture at $4x is not $2 wide"
}

# --- host side ---------------------------------------------------------------
codesign --force --sign - --entitlements tools/build/vm.entitlements.xml --options runtime "$DAEMON" \
  >/dev/null 2>&1 || fail "entitlement signing failed"
swiftc -O tools/test/host-output-running.swift -o "$HOME_DIR/host-output-running" \
  || fail "could not build the output probe"
cc -O2 -o "$HOME_DIR/smoke-tool" tools/test/smoke-tool.c || fail "could not build the smoke tool"

if [ -z "$MEDIA" ]; then
  MEDIA=$HOME_DIR/media.raw
  sh tools/build/mk-windows-media.sh "$ISO" "$MEDIA" >"$HOME_DIR/media.log" 2>&1 \
    || fail "media build failed: $(tail -3 "$HOME_DIR/media.log")"
  if grep -q 'no pinned sound driver' "$HOME_DIR/media.log"; then fail "the media has no sound driver"; fi
fi

# A fake CUPS: two queues, and an lp that keeps the PDF it is given.
mkdir -p "$HOME_DIR/fake-cups" "$HOME_DIR/printed"
printf 'OpenVM_Laser\nOffice.Colour-2\n' >"$HOME_DIR/fake-cups/list"
cat >"$HOME_DIR/fake-cups/lpstat" <<CUPS
#!/bin/sh
case "\$1" in
  -e) cat "$HOME_DIR/fake-cups/list" ;;
  -d) echo "system default destination: OpenVM_Laser" ;;
esac
CUPS
cat >"$HOME_DIR/fake-cups/lp" <<CUPS
#!/bin/sh
for last; do :; done
echo "\$*" >>"$HOME_DIR/printed/lp.args"
cp "\$last" "$HOME_DIR/printed/job\$(find "$HOME_DIR/printed" -name '*.pdf' | wc -l | tr -d ' ').pdf"
CUPS
chmod +x "$HOME_DIR/fake-cups/lpstat" "$HOME_DIR/fake-cups/lp"
export OPENVM_LPSTAT="$HOME_DIR/fake-cups/lpstat" OPENVM_LP="$HOME_DIR/fake-cups/lp"

"$DAEMON" >"$HOME_DIR/openvmd.log" 2>&1 &
PID=$!
i=0
until [ -S "$OPENVM_HOME/openvmd.sock" ]; do
  i=$((i + 1))
  [ "$i" -lt 50 ] || fail "daemon did not create its socket"
  sleep 0.1
done

# --- install -----------------------------------------------------------------
"$CTL" create "$VM" --boot-mode windows --install-media "$MEDIA" --diskSizeMB 65536 \
  --memoryMB 8192 --cpus 4 >/dev/null || fail "create failed"
"$CTL" start "$VM" >/dev/null || fail "install failed"
retry 180 agent_up || fail "the agent never answered"
echo "smoke: Windows installed and the agent answers; waiting ${SETTLE}s for first-boot setup"
sleep "$SETTLE"

# --- channel features --------------------------------------------------------
clipboard_round_trip first-boot
echo "smoke: clipboard round trip passed"

head -c 200000 /dev/urandom >"$HOME_DIR/file-source.bin"
"$CTL" file push "$VM" "$HOME_DIR/file-source.bin" smoke.bin >/dev/null || fail "file push failed"
"$CTL" file pull "$VM" smoke.bin "$HOME_DIR/file-roundtrip.bin" >/dev/null || fail "file pull failed"
cmp -s "$HOME_DIR/file-source.bin" "$HOME_DIR/file-roundtrip.bin" || fail "file round trip mismatch"
echo "smoke: file round trip passed"

mkdir -p "$HOME_DIR/shared" "$HOME_DIR/shared2"
"$CTL" share add "$VM" "$HOME_DIR/shared" >/dev/null || fail "share add failed"
"$CTL" share list "$VM" | grep -q "$HOME_DIR/shared" || fail "share list is missing the share"
"$CTL" share remove "$VM" "$HOME_DIR/shared" >/dev/null || fail "share remove failed"
if "$CTL" share list "$VM" | grep -q "$HOME_DIR/shared"; then fail "share still listed after remove"; fi
"$CTL" share add "$VM" "$HOME_DIR/shared" >/dev/null || fail "second share add failed"
echo "smoke: shares added and removed"

# --- printing ----------------------------------------------------------------
retry 60 queue_listed OpenVM_Laser || fail "the host's printer was not published"
queue_listed Office.Colour-2 || fail "the second printer was not published"
retry 24 "$CTL" printer test "$VM" --name OpenVM_Laser >/dev/null || fail "printer test refused"
retry 24 pdf_count_is 1 || fail "the first job did not reach lp"
[ "$(head -c 4 "$HOME_DIR/printed/job0.pdf")" = "%PDF" ] || fail "the job is not a PDF"
"$CTL" printer test "$VM" --name Office.Colour-2 >/dev/null || fail "second printer test refused"
retry 24 pdf_count_is 2 || fail "the second job did not reach lp"
sleep 10
pdf_count_is 2 || fail "a job was printed twice"
grep -q 'Office.Colour-2' "$HOME_DIR/printed/lp.args" || fail "a job went to the wrong queue"
printf 'OpenVM_Laser\n' >"$HOME_DIR/fake-cups/list"
retry 24 queue_gone Office.Colour-2 || fail "a printer removed on the host stayed in the guest"
if "$CTL" printer test "$VM" --name Office.Colour-2 >/dev/null 2>&1; then
  fail "a removed printer accepted a job"
fi
echo "smoke: guest print reached the host lp as a PDF, once per job, on the right queue"

# --- display -----------------------------------------------------------------
for size in "1280 720" "1600 900"; do
  set -- $size
  "$CTL" display set "$VM" --width "$1" --height "$2" | grep -q "display is $1x$2" \
    || fail "guest did not follow the host to $1x$2"
  capture=$("$CTL" display capture "$VM") || fail "display capture failed"
  "$CTL" file pull "$VM" "$capture" "$HOME_DIR/display-$1.bmp" >/dev/null || fail "capture pull failed"
  [ "$(sips -g pixelWidth "$HOME_DIR/display-$1.bmp" | awk '/pixelWidth/{print $2}')" = "$1" ] \
    || fail "capture is not $1 wide"
done
echo "smoke: guest display followed the host to 1280x720 and 1600x900"
scale_test "$VM" 2560 1600 1 bmp
scale_test "$VM" 2560 1600 2 bmp
scale_test "$VM" 3840 2400 3 bmp
# A 14-inch MacBook Pro's native size, past what the driver allows by default.
"$CTL" display set "$VM" --width 3024 --height 1964 --scale 2 | grep -q 'display is 3024x1964 at 2x' \
  || fail "guest did not take a native Retina size"
# A 13-inch MacBook Air: the panel, and its default "looks like 1470x956" at 2x.
for size in "2560 1664" "2940 1912"; do
  set -- $size
  "$CTL" display set "$VM" --width "$1" --height "$2" --scale 2 | grep -q "display is $1x$2 at 2x" \
    || fail "guest did not take $1x$2 at 2x"
done
if "$CTL" display set "$VM" --width 1024 --height 768 --scale 3 >/dev/null 2>&1; then
  fail "Windows took a scale that leaves no room for a desktop"
fi
"$CTL" display set "$VM" --width 1600 --height 900 --scale 1 | grep -q 'display is 1600x900 at 1x' \
  || fail "guest did not come back to 1x"
cmp -s "$HOME_DIR/scale-1.bmp" "$HOME_DIR/scale-2.bmp" && fail "2x looks the same as 1x"
echo "smoke: guest desktop scaled to 1x, 2x and 3x, and refused a scale with no room"

# --- drag and drop -----------------------------------------------------------
"$CTL" drag enter "$VM" >/dev/null || fail "guest refused a drag"
mkdir -p "$HOME_DIR/dropped/My Tree/sub"
printf 'hello' >"$HOME_DIR/dropped/note.txt"
printf 'deepest' >"$HOME_DIR/dropped/My Tree/sub/deep.bin"
"$CTL" drag drop "$VM" "$HOME_DIR/dropped/note.txt" "$HOME_DIR/dropped/My Tree" \
  | grep -q 'dropped note.txt, My Tree (12 bytes)' || fail "drop of a file and a tree failed"
"$CTL" drag drop "$VM" "$HOME_DIR/dropped/note.txt" | grep -q 'dropped note (2).txt' \
  || fail "a dropped name in use was not kept apart"
head -c 2147483648 /dev/urandom >"$HOME_DIR/dropped/big.bin"
"$CTL" drag drop "$VM" "$HOME_DIR/dropped/big.bin" >"$HOME_DIR/big-drop.out" 2>&1 &
big_drop=$!
i=0
while kill -0 "$big_drop" 2>/dev/null; do
  "$CTL" ping "$VM" >/dev/null || fail "the channel stopped answering during a drop"
  i=$((i + 1))
  if [ "$i" = 3 ]; then
    "$CTL" share add "$VM" "$HOME_DIR/shared2" 2>&1 | grep -q 'a drop is running' \
      || fail "a share change during a drop was not refused"
  fi
  sleep 0.2
done
wait "$big_drop" || fail "large drop failed: $(cat "$HOME_DIR/big-drop.out")"
grep -q 'dropped big.bin (2147483648 bytes)' "$HOME_DIR/big-drop.out" || fail "large drop lost bytes"
[ "$i" -ge 5 ] || fail "the large drop was too quick to prove anything ($i pings)"
echo "smoke: files dropped onto the guest desktop ($i pings answered during a 2 GiB drop)"

# --- suspend -----------------------------------------------------------------
# The scale must be applied again after a resume; the agent's log counts each time.
"$CTL" display set "$VM" --width 2560 --height 1600 --scale 2 >/dev/null || fail "scale before suspend failed"
"$CTL" suspend "$VM" | grep -q "suspended $VM" || fail "suspend failed"
sleep 3
"$CTL" resume "$VM" >/dev/null || fail "resume failed"
retry 12 agent_up || fail "the agent did not answer after resume"
capture=$("$CTL" display capture "$VM") || fail "capture after resume failed"
"$CTL" file pull "$VM" "$capture" "$HOME_DIR/resumed.bmp" >/dev/null || fail "capture pull failed"
[ "$(sips -g pixelWidth "$HOME_DIR/resumed.bmp" | awk '/pixelWidth/{print $2}')" = 2560 ] \
  || fail "the mode did not survive a resume"
"$CTL" display set "$VM" --width 1600 --height 900 --scale 1 >/dev/null || fail "scale after resume failed"
echo "smoke: suspend/resume and agent re-ping passed"

# --- sound, and a restart with a new time zone -------------------------------
default_sound=$("$CTL" audio status "$VM" 2>&1)
echo "$default_sound" | grep -q 'state=off' || fail "sound is not off by default: $default_sound"
if "$CTL" audio test "$VM" >/dev/null 2>&1; then fail "a tone played with sound off"; fi
"$CTL" audio enable "$VM" >/dev/null 2>&1
[ $? = 2 ] || fail "enable without --test-mode was not refused"
"$CTL" audio enable "$VM" --test-mode | grep -q 'state=pending' || fail "enable failed"
restart_guest Europe/Berlin
# The printer sync after a restart must not hold the agent.
i=0
while [ "$i" -lt 40 ]; do
  agent_up || fail "the agent stopped answering after a restart"
  i=$((i + 1))
  sleep 0.5
done
retry 24 sh -c "'$CTL' audio status $VM | grep -q 'state=on'" || fail "sound did not come on after a restart"
clipboard_round_trip after-restart

# The Mac holds its output for seconds after a tone, so idle must be seen first.
probe=$HOME_DIR/host-output-running
idle=$("$probe")
"$CTL" audio test "$VM" >"$HOME_DIR/tone.out" 2>&1 &
tone=$!
seen=false
while kill -0 "$tone" 2>/dev/null; do
  [ "$("$probe")" = true ] && seen=true
  sleep 0.2
done
wait "$tone" || fail "audio test failed: $(cat "$HOME_DIR/tone.out")"
if [ "$idle" = false ]; then
  [ "$seen" = true ] || fail "the Mac's output did not start for the tone"
  retry 6 sh -c "[ \"\$('$probe')\" = false ]" || fail "the Mac's output did not stop after the tone"
  echo "smoke: guest audio played through the host (output idle, running, idle)"
else
  echo "smoke: guest audio played (the Mac was already playing, so host output proves nothing here)"
fi

"$CTL" audio disable "$VM" | grep -q 'state=off' || fail "disable failed"
restart_guest
after_disable=$("$CTL" audio status "$VM" 2>&1)
echo "$after_disable" | grep -q 'state=off' || fail "sound is not off after disable: $after_disable"
if "$CTL" audio test "$VM" >/dev/null 2>&1; then fail "a tone played after disable"; fi
echo "smoke: sound off by default, on after enable, off after disable"

# --- the guest's disk --------------------------------------------------------
# The guest stops itself and the record follows with no further command: only the
# framework's end-of-guest report can do that.
"$CTL" stop "$VM" --no-wait | grep -q "stopping $VM" || fail "no-wait stop output wrong"
retry 90 sh -c "'$CTL' list | grep -q 'state=stopped'" || fail "the record did not follow the guest's own shutdown"
"$CTL" start "$VM" >/dev/null || fail "start after a guest-initiated stop failed"
retry 180 agent_up || fail "the agent did not answer after a guest-initiated stop"
echo "smoke: the record followed the guest's own shutdown, and the VM started again"
"$CTL" stop "$VM" | grep -q "stopped $VM" || fail "final stop failed"
attached=$(hdiutil attach -readonly -nobrowse -noverify -imagekey diskimage-class=CRawDiskImage \
  "$OPENVM_HOME/disks/$VM/disk.raw" 2>/dev/null) || fail "could not read the guest's disk"
MOUNT_DEV=$(echo "$attached" | head -1 | awk '{print $1}')
root=$(echo "$attached" | awk -F'\t' '/Windows/{print $NF}' | head -1)
[ -d "$root/Windows" ] || fail "the guest's disk has no Windows volume"
desktop="$root/Users/openvm/Desktop"
cmp -s "$desktop/note.txt" "$HOME_DIR/dropped/note.txt" || fail "the dropped file is not on the Desktop"
cmp -s "$desktop/note (2).txt" "$HOME_DIR/dropped/note.txt" || fail "the second drop is not on the Desktop"
cmp -s "$desktop/My Tree/sub/deep.bin" "$HOME_DIR/dropped/My Tree/sub/deep.bin" \
  || fail "the dropped tree is not on the Desktop"
cmp -s "$desktop/big.bin" "$HOME_DIR/dropped/big.bin" || fail "the large drop differs on the Desktop"
echo "smoke: dropped files match on the guest's disk"
# Set once before the suspend and once by the resume, at least.
[ "$(tr -d '\r' <"$root/openvm/agent.log" | grep -c 'display holds 2560x1600 at scale 2')" -ge 3 ] \
  || fail "the scale was not re-applied after resume"
echo "smoke: the scale was applied again after resume"
# The list of all zones lives in the SOFTWARE hive, so a zone name in SYSTEM is the one in use.
"$HOME_DIR/smoke-tool" has-utf16 "$root/Windows/System32/config/SYSTEM" "W. Europe Standard Time" \
  || fail "the guest's time zone did not change"
echo "smoke: the guest took the host's time zone"
[ -e "$root/openvm/sound/sound.failed" ] && fail "the sound install recorded a failure"
[ -e "$root/openvm/sound/tone.wav" ] && fail "disable left the tone behind"
echo "smoke: okay"
