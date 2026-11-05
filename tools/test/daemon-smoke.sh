#!/bin/sh
# End-to-end smoke test: openvmd + openvmctl against a throwaway OPENVM_HOME.
# Exit 0 = all assertions pass. Assumes `swift build` has already succeeded.
set -u

cd "$(dirname "$0")/../.." || exit 1
DAEMON=.build/debug/openvmd
CTL=.build/debug/openvmctl
HOME_DIR=$(mktemp -d /tmp/openvm-smoke.XXXXXX)
export OPENVM_HOME="$HOME_DIR"
# Exercise registry-only CLI behavior before the optional real-guest phase.
# Preserve a caller-provided support path for that phase; otherwise use default.
REAL_SUPPORT=${OPENVM_SUPPORT:-}
HTTP_PORT=${OPENVM_SMOKE_HTTP_PORT:-8123}
mkdir -p "$HOME_DIR/no-support"
export OPENVM_SUPPORT="$HOME_DIR/no-support"

SAVED_CLIPBOARD=$(pbpaste)

cleanup() {
  printf '%s' "$SAVED_CLIPBOARD" | pbcopy
  [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null || true
  [ -n "${HTTP_PID:-}" ] && kill "$HTTP_PID" 2>/dev/null || true
  if [ "${OPENVM_SMOKE_KEEP:-0}" = "1" ]; then
    echo "smoke: artifacts retained at $HOME_DIR" >&2
  else
    rm -rf "$HOME_DIR"
  fi
}

fail() {
  echo "smoke: FAIL $1" >&2
  if [ -f "$HOME_DIR/srv1.console.log" ]; then
    echo "smoke: guest console tail:" >&2
    tail -80 "$HOME_DIR/srv1.console.log" >&2
  fi
  if [ -f "$HOME_DIR/http.log" ]; then
    echo "smoke: overlay HTTP log:" >&2
    cat "$HOME_DIR/http.log" >&2
  fi
  exit 1
}

wait_for_daemon() {
  # Swift startup can take longer than a fixed half-second, especially after
  # codesign invalidates the executable page cache. Wait on the actual socket.
  for _ in $(seq 1 50); do
    kill -0 "$PID" 2>/dev/null || return 1
    [ -S "$OPENVM_HOME/openvmd.sock" ] && return 0
    sleep 0.1
  done
  return 1
}

# The daemon carries the Virtualization entitlement (a real start boots a guest).
codesign --force --sign - --entitlements tools/build/vm.entitlements.xml "$DAEMON" >/dev/null \
  || fail "entitlement signing failed"

"$DAEMON" &
PID=$!
trap cleanup EXIT
wait_for_daemon || fail "daemon did not create its socket"

"$CTL" create srv1 >/dev/null || fail "create"
"$CTL" create srv1 2>/dev/null && fail "duplicate create accepted"
"$CTL" list | grep -q "name=srv1" || fail "list missing srv1"
"$CTL" list | grep -q "state=stopped" || fail "srv1 not stopped after create"

"$CTL" start srv1 | grep -q "started srv1" || fail "start output wrong"
"$CTL" list | grep -q "state=running" || fail "start did not transition"
"$CTL" start srv1 2>/dev/null && fail "double start accepted"
"$CTL" start nope 2>/dev/null && fail "start of unknown vm accepted"

"$CTL" stop srv1 | grep -q "stopped srv1" || fail "stop output wrong"
"$CTL" list | grep -q "state=stopped" || fail "stop did not transition"

if [ "${OPENVM_SMOKE_REAL:-0}" = "1" ]; then
  # Real-guest acceptance: first start installs Alpine to the
  # attached disk; second start boots with that disk as root. Both must answer
  # the channel ping.
  tools/build/mk-guest-overlay.sh "$HOME_DIR/overlay" || fail "overlay build failed"
  cc -O2 -o "$HOME_DIR/smoke-tool" tools/test/smoke-tool.c || fail "could not build the smoke tool"
  "$HOME_DIR/smoke-tool" serve "$HOME_DIR/overlay" "$HTTP_PORT" >"$HOME_DIR/http.log" 2>&1 &
  HTTP_PID=$!
  trap cleanup EXIT
  if [ -n "$REAL_SUPPORT" ]; then
    export OPENVM_SUPPORT="$REAL_SUPPORT"
  else
    unset OPENVM_SUPPORT
  fi
  export OPENVM_APKOVL_URL="http://192.168.64.1:$HTTP_PORT/openvm.apkovl.tar.gz"
  # A host with no printers cannot prove the print path, so the daemon gets a
  # stand-in CUPS: one queue to publish, and an lp that keeps what it is handed.
  mkdir -p "$HOME_DIR/fake-cups" "$HOME_DIR/printed"
  cat >"$HOME_DIR/fake-cups/lpstat" <<'FAKE'
#!/bin/sh
case "$1" in
  -e) echo OpenVM_Smoke ;;
  -d) echo "system default destination: OpenVM_Smoke" ;;
esac
FAKE
  cat >"$HOME_DIR/fake-cups/lp" <<FAKE
#!/bin/sh
for last; do :; done
echo "\$*" >>"$HOME_DIR/printed/lp.args"
cp "\$last" "$HOME_DIR/printed/job.pdf"
FAKE
  chmod +x "$HOME_DIR/fake-cups/lpstat" "$HOME_DIR/fake-cups/lp"
  export OPENVM_LPSTAT="$HOME_DIR/fake-cups/lpstat" OPENVM_LP="$HOME_DIR/fake-cups/lp"
  # openvmd reads the overlay URL from its environment at process launch.
  # Restart after exporting it so the guest kernel command line receives it.
  kill "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
  "$DAEMON" &
  PID=$!
  wait_for_daemon || fail "daemon did not restart with overlay URL"
  "$CTL" start srv1 | grep -q "guest booted" \
    || fail "real guest boot failed (see $HOME_DIR/srv1.console.log)"
  "$CTL" list | grep -q "state=running" || fail "state not running after guest boot"
  # A successful disk-backed start must wait until the agent is listening.
  "$CTL" ping srv1 | grep -q "pong srv1" || fail "first-boot agent not ready after start"
  echo "smoke: first-boot install and guest agent ping passed"
  "$CTL" stop srv1 | grep -q "stopped srv1" || fail "stop output wrong after guest boot"
  "$CTL" list | grep -q "state=stopped" || fail "state not stopped after guest stop"
  cp "$HOME_DIR/srv1.console.log" "$HOME_DIR/srv1.install.console.log"
  "$CTL" start srv1 | grep -q "guest booted" \
    || fail "persistent disk boot failed (see $HOME_DIR/srv1.console.log)"
  "$CTL" ping srv1 | grep -q "pong srv1" || fail "persistent agent not ready after start"
  "$CTL" stop srv1 | grep -q "stopped srv1" || fail "stop output wrong before set --tz"
  "$CTL" set srv1 --tz Europe/Berlin | grep -q "tz=Europe/Berlin" || fail "set --tz output wrong"
  "$CTL" start srv1 | grep -q "guest booted" \
    || fail "boot after set --tz failed (see $HOME_DIR/srv1.console.log)"
  grep -q 'openvm-tools: guest timezone applied (Europe/Berlin)' "$HOME_DIR/srv1.console.log" \
    || fail "persistent guest did not adopt the requested timezone"
  grep -q 'EXT4-fs (vda[0-9]*): mounted filesystem' "$HOME_DIR/srv1.console.log" \
    || fail "persistent guest did not mount an ext4 root"
  grep -q 'openvm-tools: starting persistent guest agent' "$HOME_DIR/srv1.console.log" \
    || fail "persistent guest did not start its OpenRC agent service"
  grep -q 'openvm-tools: listening on vsock port 52' "$HOME_DIR/srv1.console.log" \
    || fail "persistent agent did not report a vsock listener"
  grep -q 'openvm-tools: host clock applied' "$HOME_DIR/srv1.console.log" \
    || fail "persistent guest did not adopt the host clock"
  "$HOME_DIR/smoke-tool" pattern "$HOME_DIR/file-source.bin" 131101 || fail "could not write the file pattern"
  printf 'replace this destination\n' >"$HOME_DIR/file-roundtrip.bin"
  "$CTL" file push srv1 "$HOME_DIR/file-source.bin" guest-smoke.bin \
    | grep -q 'copied 131101 bytes' || fail "file push failed"
  "$CTL" file pull srv1 guest-smoke.bin "$HOME_DIR/file-roundtrip.bin" \
    | grep -q 'copied 131101 bytes' || fail "file pull failed"
  cmp -s "$HOME_DIR/file-source.bin" "$HOME_DIR/file-roundtrip.bin" \
    || fail "file round-trip bytes differ"
  echo "smoke: binary file push/pull round-trip passed"
  mkdir -p "$HOME_DIR/shared"
  printf 'shared folder probe\n' >"$HOME_DIR/shared/hello.txt"
  "$CTL" share add srv1 "$HOME_DIR/shared" /mnt/openvm/shared \
    | grep -q 'share added' || fail "share add failed"
  "$CTL" share list srv1 | grep -q "$HOME_DIR/shared" || fail "share list missing the share"
  echo "smoke: shared folder mounted in the guest"
  # Live removal: the guest unmounts and the virtio-fs share set drops it.
  "$CTL" share remove srv1 "$HOME_DIR/shared" | grep -q 'share removed' || fail "share remove failed"
  if "$CTL" share list srv1 | grep -q "$HOME_DIR/shared"; then fail "share still listed after remove"; fi
  # ... and adding it back works on the same running VM.
  "$CTL" share add srv1 "$HOME_DIR/shared" /mnt/openvm/shared \
    | grep -q 'share added' || fail "share re-add failed"
  echo "smoke: shared folder removed and re-added live"
  # The persistent guest's XFCE session owns the X clipboard, through xclip;
  # the clipboard bridge must round-trip host↔guest through a real X session.
  smoke_text="openvm-clipboard-smoke-$RANDOM"
  printf '%s' "$smoke_text" | pbcopy || fail "pbcopy failed"
  # `start` returns when the agent answers; the desktop session follows.
  i=0
  until "$CTL" clipboard push srv1 2>/dev/null | grep -q "copied to guest"; do
    i=$((i + 1)); [ "$i" -lt 30 ] || fail "clipboard push failed"
    sleep 2
  done
  "$CTL" clipboard pull srv1 | grep -q "copied to host" || fail "clipboard pull failed"
  [ "$(pbpaste)" = "$smoke_text" ] || fail "clipboard round-trip mismatch: $(pbpaste)"
  echo "smoke: desktop clipboard round-trip passed"
  # Printing: the host's queue appears in the guest, and a page printed there
  # comes back to the host's lp as a PDF.
  i=0
  until "$CTL" printer list srv1 | grep -q '^OpenVM_Smoke$'; do
    i=$((i + 1)); [ "$i" -lt 30 ] || fail "host printer never appeared in the guest"
    sleep 2
  done
  "$CTL" printer test srv1 --name OpenVM_Smoke >/dev/null || fail "printer test refused"
  i=0
  until [ -s "$HOME_DIR/printed/job.pdf" ]; do
    i=$((i + 1)); [ "$i" -lt 45 ] || fail "printed job never reached the host (see $HOME_DIR/srv1.console.log)"
    sleep 2
  done
  [ "$(head -c 5 "$HOME_DIR/printed/job.pdf")" = "%PDF-" ] || fail "printed job is not a PDF"
  grep -q -- '-d OpenVM_Smoke' "$HOME_DIR/printed/lp.args" || fail "job went to the wrong queue"
  echo "smoke: guest print reached the host lp as a PDF"
  # Dynamic resolution: the daemon only reports success once the guest's X
  # server says it holds the mode.
  for mode in "1280 720" "1600 900"; do
    set -- $mode
    "$CTL" display set srv1 --width "$1" --height "$2" | grep -q "display is $1x$2" \
      || fail "display did not reach $1x$2"
  done
  capture=$("$CTL" display capture srv1) || fail "display capture failed"
  "$CTL" file pull srv1 "$capture" "$HOME_DIR/$capture" >/dev/null || fail "capture pull failed"
  echo "smoke: guest display followed the host to 1280x720 and 1600x900"
  # HiDPI: the desktop's own scale, read back from its settings.
  for scale in "2560 1600 1" "2560 1600 2" "3840 2400 3"; do
    set -- $scale
    "$CTL" display set srv1 --width "$1" --height "$2" --scale "$3" \
      | grep -q "display is $1x$2 at $3x" || fail "guest did not take $1x$2 at $3x"
    sleep 2
    capture=$("$CTL" display capture srv1) || fail "capture at $3x failed"
    "$CTL" file pull srv1 "$capture" "$HOME_DIR/scale-$3.png" >/dev/null || fail "capture pull failed"
    [ "$(sips -g pixelWidth "$HOME_DIR/scale-$3.png" | awk '/pixelWidth/{print $2}')" = "$1" ] \
      || fail "capture at $3x is not $1 wide"
  done
  "$CTL" display set srv1 --width 1600 --height 900 --scale 1 | grep -q 'display is 1600x900 at 1x' \
    || fail "guest did not come back to 1x"
  cmp -s "$HOME_DIR/scale-1.png" "$HOME_DIR/scale-2.png" && fail "2x looks the same as 1x"
  echo "smoke: guest desktop scaled to 1x, 2x and 3x"
  # A real desktop, not a blank root window: sizes and a compressed all-black
  # 1600x900 PNG is a few KB, so the size says whether anything was drawn.
  [ "$(sips -g pixelWidth "$HOME_DIR/$capture" | awk '/pixelWidth/{print $2}')" = 1600 ] \
    || fail "capture is not 1600 wide"
  [ "$(wc -c < "$HOME_DIR/$capture")" -gt 20000 ] || fail "desktop capture looks blank"
  grep -q 'openvm-desktop:   input2' "$HOME_DIR/srv1.console.log" \
    || fail "the desktop session is missing an input device"
  echo "smoke: the XFCE desktop is drawn"
  # Drag and drop: a file, a tree and a name in use, onto the guest's Desktop.
  "$CTL" drag enter srv1 >/dev/null || fail "guest refused a drag"
  mkdir -p "$HOME_DIR/dropped/My Tree/sub"
  printf 'hello' >"$HOME_DIR/dropped/note.txt"
  printf 'deepest' >"$HOME_DIR/dropped/My Tree/sub/deep.bin"
  "$CTL" drag drop srv1 "$HOME_DIR/dropped/note.txt" "$HOME_DIR/dropped/My Tree" \
    | grep -q 'dropped note.txt, My Tree (12 bytes)' || fail "drop of a file and a tree failed"
  "$CTL" drag drop srv1 "$HOME_DIR/dropped/note.txt" | grep -q 'dropped note (2).txt' \
    || fail "a dropped name in use was not kept apart"
  # A large drop must not hold the channel, and a share change must wait for it.
  head -c 2147483648 /dev/urandom >"$HOME_DIR/dropped/big.bin"
  "$CTL" drag drop srv1 "$HOME_DIR/dropped/big.bin" >"$HOME_DIR/big-drop.out" 2>&1 &
  big_drop=$!
  mkdir -p "$HOME_DIR/shared2"
  i=0
  while kill -0 "$big_drop" 2>/dev/null; do
    "$CTL" ping srv1 >/dev/null || fail "the channel stopped answering during a drop"
    i=$((i + 1))
    if [ "$i" = 3 ]; then
      "$CTL" share add srv1 "$HOME_DIR/shared2" /mnt/openvm/shared2 2>&1 | grep -q 'a drop is running' \
        || fail "a share change during a drop was not refused"
    fi
    sleep 0.2
  done
  wait "$big_drop" || fail "large drop failed: $(cat "$HOME_DIR/big-drop.out")"
  grep -q 'dropped big.bin (2147483648 bytes)' "$HOME_DIR/big-drop.out" || fail "large drop lost bytes"
  [ "$i" -ge 5 ] || fail "the large drop was too quick to prove anything ($i pings)"
  [ -z "$(find "$HOME_DIR/drops" -mindepth 2 2>/dev/null)" ] || fail "drop staging was left behind"
  capture=$("$CTL" display capture srv1) || fail "capture after drop failed"
  "$CTL" file pull srv1 "$capture" "$HOME_DIR/after-drop.png" >/dev/null || fail "capture pull failed"
  echo "smoke: files dropped onto the guest desktop ($i pings answered during a 2 GiB drop)"
  # Sound: the guest plays, and the Mac's output starts for it and stops after it.
  # The host half means something only if nothing else on the Mac is playing.
  idle=$("$CTL" audio status srv1)
  echo "$idle" | grep -q 'device=none' && fail "the guest has no sound card"
  echo "$idle" | grep -q 'running=false' || fail "the guest was already playing: $idle"
  "$CTL" audio test srv1 >/dev/null || fail "audio test failed"
  sleep 1
  playing=$("$CTL" audio status srv1)
  echo "$playing" | grep -q 'running=true' || fail "audio is not running: $playing"
  echo "$playing" | grep -q 'hostOutputRunning=true' || fail "the Mac's output is not running: $playing"
  sleep 5
  after=$("$CTL" audio status srv1)
  echo "$after" | grep -q 'running=false' || fail "the tone did not stop: $after"
  if echo "$idle" | grep -q 'hostOutputRunning=false'; then
    # The Mac holds its output for about 5 s after the guest stops.
    waited=0
    while [ "$waited" -lt 15 ]; do
      after=$("$CTL" audio status srv1)
      echo "$after" | grep -q 'hostOutputRunning=false' && break
      sleep 1
      waited=$((waited + 1))
    done
    echo "$after" | grep -q 'hostOutputRunning=false' || fail "the Mac's output did not stop: $after"
    echo "smoke: guest audio played through the host (output idle, running, idle)"
  else
    echo "smoke: guest audio played (the Mac was already playing, so host output proves nothing here)"
  fi
  # The scale must be applied again after a resume, not just survive in the guest.
  "$CTL" display set srv1 --width 2560 --height 1600 --scale 2 >/dev/null || fail "scale before suspend failed"
  scale_applied() { grep -c 'display holds 2560x1600 at scale 2' "$HOME_DIR/srv1.console.log"; }
  applied=$(scale_applied)
  "$CTL" suspend srv1 | grep -q "suspended srv1" || fail "suspend output wrong"
  "$CTL" list | grep -q "state=suspended" || fail "suspend did not transition"
  "$CTL" ping srv1 2>/dev/null && fail "paused guest answered a channel ping"
  # The guest flushes before it is paused — the same handshake the host sleep
  # uses, so the smoke covers it.
  grep -q "guest quiesced" "$HOME_DIR/srv1.console.log" || fail "the guest did not flush before the suspend"
  "$CTL" resume srv1 | grep -q "resumed srv1" || fail "resume output wrong"
  "$CTL" list | grep -q "state=running" || fail "resume did not transition"
  "$CTL" ping srv1 | grep -q "pong srv1" || fail "agent not responding after resume"
  i=0
  until [ "$(scale_applied)" -gt "$applied" ]; do
    i=$((i + 1)); [ "$i" -lt 30 ] || fail "the scale was not re-applied after resume"
    sleep 1
  done
  "$CTL" display set srv1 --width 1600 --height 900 --scale 1 >/dev/null || fail "scale after resume failed"
  echo "smoke: suspend/resume and agent re-ping passed"
  "$CTL" stop srv1 | grep -q "stopped srv1" || fail "stop output wrong after persistent boot"
  "$CTL" list | grep -q "state=stopped" || fail "state not stopped after persistent guest stop"
  echo "smoke: persistent disk boot and guest agent ping passed"
fi

echo "smoke: okay"
