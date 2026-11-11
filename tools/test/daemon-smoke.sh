#!/bin/sh
# End-to-end smoke test: openvmd + openvmctl against a throwaway OPENVM_HOME, with no guest booted.
# It proves what a VM can be made as, and what happens to an Alpine guest left by an earlier openVM.
# Exit 0 = all assertions pass. Assumes `swift build` has already succeeded.
# A real guest is covered by `make windows-smoke`.
set -u

cd "$(dirname "$0")/../.." || exit 1
DAEMON=.build/debug/openvmd
CTL=.build/debug/openvmctl
HOME_DIR=$(mktemp -d /tmp/openvm-smoke.XXXXXX)
export OPENVM_HOME="$HOME_DIR"

cleanup() {
  [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null || true
  if [ "${OPENVM_SMOKE_KEEP:-0}" = "1" ]; then
    echo "smoke: artifacts retained at $HOME_DIR" >&2
  else
    rm -rf "$HOME_DIR"
  fi
}

fail() {
  echo "smoke: FAIL $1" >&2
  exit 1
}

wait_for_daemon() {
  for _ in $(seq 1 50); do
    kill -0 "$PID" 2>/dev/null || return 1
    # A socket file is not a listening daemon: a killed daemon can leave its file behind, and the next
    # one unlinks and rebinds it. Ask it something.
    "$CTL" list >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

# Two records an earlier openVM wrote for its own Alpine guests: one from before records said
# which system they hold, one that says "linux". The second was running when that openVM quit.
mkdir -p "$HOME_DIR/disks/srv1"
: > "$HOME_DIR/disks/srv1/disk.raw"
cat > "$HOME_DIR/vms.json" <<JSON
{"vms":[
{"uuid":"11111111-2222-3333-4444-555555555555","name":"oldest","state":"stopped","cpus":2,"memoryMB":2048,"createdAt":"2026-01-01T00:00:00Z"},
{"uuid":"22222222-2222-3333-4444-555555555555","name":"srv1","state":"running","cpus":4,"memoryMB":4096,"diskPath":"$HOME_DIR/disks/srv1/disk.raw","bootMode":"linux","createdAt":"2026-01-01T00:00:00Z"}
]}
JSON

"$DAEMON" &
PID=$!
trap cleanup EXIT
wait_for_daemon || fail "daemon did not answer"

# The old records load, and nothing is left "running" with no guest behind it.
"$CTL" list | grep -q "name=oldest" || fail "the oldest Alpine record did not load"
"$CTL" list | grep "name=srv1" | grep -q "state=stopped" || fail "srv1 was not recorded as stopped"

# An Alpine guest is not started, and the answer says what deleting it costs.
out=$("$CTL" start srv1 2>&1) && fail "an Alpine guest was started"
echo "$out" | grep -q "no longer runs" || fail "start did not say why: $out"
echo "$out" | grep -q "$HOME_DIR/disks/srv1/disk.raw" || fail "start did not name the disk: $out"
"$CTL" start oldest 2>/dev/null && fail "the oldest Alpine guest was started"
"$CTL" list | grep "name=srv1" | grep -q "state=stopped" || fail "a refused start changed the state"
# Its mode cannot be renamed into another system.
"$CTL" set srv1 --boot-mode windows 2>/dev/null && fail "an Alpine guest was turned into a Windows one"
"$CTL" set srv1 --boot-mode linux 2>/dev/null && fail "set --boot-mode linux was accepted"
# What does not need a guest still works, and so does deleting it.
"$CTL" set srv1 --cpus 2 >/dev/null || fail "set --cpus on an Alpine record"
"$CTL" info srv1 | grep -q "cpus=2" || fail "set --cpus did not apply"
"$CTL" delete srv1 >/dev/null || fail "delete of an Alpine record"
[ ! -e "$HOME_DIR/disks/srv1" ] || fail "delete left the disk folder"
"$CTL" delete oldest >/dev/null || fail "delete of the oldest Alpine record"

# A new VM is Windows, or a Linux from its own ISO. Nothing else is made.
out=$("$CTL" create plain 2>&1) && fail "create with no system was accepted"
echo "$out" | grep -q "create needs --boot-mode windows or linux-iso" || fail "create did not say what it needs: $out"
out=$("$CTL" create alp --boot-mode linux 2>&1) && fail "an Alpine guest was created"
echo "$out" | grep -q "no longer makes Alpine guests" || fail "create did not say what replaced Alpine: $out"
"$CTL" create odd --boot-mode bsd >/dev/null 2>&1 && fail "an unknown system was accepted"
"$CTL" create iso1 --boot-mode linux-iso 2>/dev/null && fail "linux-iso without an ISO was accepted"
"$CTL" list | grep -q "name=" && fail "a refused create left a record"
[ ! -e "$HOME_DIR/disks/plain" ] && [ ! -e "$HOME_DIR/disks/alp" ] || fail "a refused create left a disk"

: > "$HOME_DIR/distro.iso"
"$CTL" create iso1 --boot-mode linux-iso --install-media "$HOME_DIR/distro.iso" >/dev/null || fail "create linux-iso"
"$CTL" create iso1 --boot-mode linux-iso --install-media "$HOME_DIR/distro.iso" 2>/dev/null && fail "duplicate create accepted"
"$CTL" list | grep "name=iso1" | grep -q "state=stopped" || fail "iso1 not stopped after create"
"$CTL" info iso1 | grep -q "bootMode=linux-iso" || fail "iso1 has the wrong mode"
"$CTL" start nope 2>/dev/null && fail "start of unknown vm accepted"
"$CTL" delete iso1 >/dev/null || fail "delete iso1"
[ -e "$HOME_DIR/distro.iso" ] || fail "delete removed the person's own ISO"

"$CTL" create win1 --boot-mode windows >/dev/null || fail "create windows"
"$CTL" info win1 | grep -q "bootMode=windows" || fail "win1 has the wrong mode"
"$CTL" delete win1 >/dev/null || fail "delete win1"

echo "smoke: PASS"
