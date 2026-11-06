# Daemon protocol

How `openvmctl` (and later the GUI) talks to `openvmd`. The daemon uses the OVMC frame and
message layer (see [guest-protocol.md](guest-protocol.md)) with
**CBOR bodies, version 1**, over a **Unix socket**. The separate host↔guest channel uses the
same OVMC framing over a virtio-vsock connection.

The daemon answers `hello` and `echo`, the VM lifecycle, and the operations a running guest serves, all listed in the table below. `start` boots a Linux guest with `VZLinuxBootLoader`, or a Windows guest through EFI, chosen by the record's `bootMode`. Linux needs the artifacts from `tools/build/fetch-linux.sh`; without them a Linux `start` only moves the record to `running`.

## Transport

Socket path: `$OPENVM_HOME/openvmd.sock` (env override; default `~/.openvm/openvmd.sock`).
The daemon listens and serves **every connection on its own thread**, so a long boot does
not stop another client; access control is the filesystem's
(per-user directory, so another user cannot reach the socket). Frames: see guest-protocol.md §Frame
(magic `OVMC`, u16 version, u16 type, u16 flags, u32 payload length). 1 MiB payload cap.

## Handshake

Client → `hello` (type 1), body `{"product": "openvmctl"}`, `version` defaults to 1, `id` = 1.
Daemon → `helloReply` (type 2), body `{"accepted": true, "version": 1}`.
The client may proceed on `accepted: true`; on `false` it disconnects.

## Requests: `vmRequest` (type 6)

Body map: `{"op": <op string>, "args": {…}}`. `id` carries the correlation id;
the daemon replies on the same id.

| op    | args                                        |daemon action                        |
|-------|---------------------------------------------|-------------------------------------|
| create| `name` (text, required); `cpus`, `memoryMB`, `diskSizeMB` (optional; default 32768); `boot-mode` (`linux`/`windows`), `install-media` (Windows: media from `tools/build/mk-windows-media.sh`, used for the install boot on first start) | creates a sparse raw disk under `$OPENVM_HOME/disks/<name>/disk.raw` and registers the VM |
| list  | (none)                                      | read-only scan of the registry      |
| info  | `id` (name or uuid)                         | read-only scan of one registry record (same row shape as `list`) |
| start | `id` (name or uuid)                         | attaches the VM raw disk as virtio-blk and boots Alpine netboot if artifacts exist, else registry-only; `stopped → running` |
| stop  | `id`; `wait` (bool, default true) | stops the live guest if one is running; `running → stopped`. A guest still booting is cancelled instead (the `start` then fails with `cancelled`). `wait: false` returns once the guest has been asked to stop and the record follows it (`openvmctl stop <vm> --no-wait`) |
| delete| `id`                                        | sweeps the raw disk (+ sidecars) and removes the record; requires `stopped` |
| suspend| `id`                                       | pauses the live guest (VZ pause) and records `suspended`; needs this daemon to hold the live guest |
| resume | `id`                                       | unpauses the suspended live guest and records `running`; needs this daemon to hold the live guest |
| set    | `id`; `cpus`, `memoryMB`, `tz`, `boot-mode`, `variable-store-path`, `clipboard-sync` (bool) (at least one) | updates the record. `cpus`, `memoryMB`, `boot-mode` and `variable-store-path` need a `stopped` VM; `tz` and `clipboard-sync` may change while it runs. `cpus` is 1 to 32 and no more than the Mac allows, `memoryMB` is 128 to what the Mac allows (see `host-info`); `tz` is an IANA zone name, applied to the guest at the next boot or resume) |
| host-info | (none) | answers `maxCpus` (at most 32), `maxMemoryMB`, `freeDiskMB` (where VMs live), `linuxReady` (the Linux guest files are fetched) and `hostWimlib` (`wimlib-imagex` is installed), so a client offers only choices that will work. Also `openvmctl host-info` |
| stop-all | (none) | stops every live guest at once, the way quitting the app does, and answers how many it stopped. A guest still booting is cancelled |
| ping  | `id` (name or uuid)                         | host sends `echoRequest` over the guest's dedicated channel port and waits for the in-guest agent's `echoReply`; needs this daemon to hold the live guest |
| clipboard-write | `id`, `text` (UTF-8 text) | sends host clipboard text to the guest agent |
| clipboard-read | `id` | reads guest clipboard text from the guest agent |
| file-write | `id`, `name`, `transferId`, `offset`, `data`, `eof` | appends a bounded binary chunk to a staged guest file |
| file-read | `id`, `name`, `offset`, `length` | reads one bounded binary chunk from a staged guest file |
| file-abort | `id`, `name`, `transferId` | removes an incomplete upload's temporary file |
| share-add | `id`; `hostPath` (an existing host directory), `guestPath` (optional; defaults to `/mnt/openvm/<basename>`) | adds the directory to the VM's virtio-fs share set and mounts it in the guest (live VMs), or records it for the next boot |
| share-remove | `id`, `hostPath` | unmounts the share in the guest and drops the export and the record entry |
| share-list | `id` | lists the record's shares as `hostPath`/`guestPath` rows |
| drag | `id`, `op` (`enter`, `leave`, `drop`, `status`); `paths` for `drop` | stages host files and has the guest put them on the user's Desktop |
| printer | `id`, `op` (`list`, `test`), `name` for `test` | lists the guest's queues, or prints a test page |
| audio | `id`, `op` (`status`, `test`, `enable`, `disable`); `enable` also needs `testMode: true` | reports or tests guest sound; adds `hostOutputRunning`. `enable` and `disable` are Windows only |
| display | `id`; `op` `capture`, or `width`, `height` and optional `scale` (1 to 3) | changes the guest's mode and scale, or saves its screen for `file pull` |

`list` and `info` rows also carry `bootMode`, `timezone` (when set), `diskBytes` (the disk's size as the guest sees it), `activity` (the op in flight, absent when idle), `installing` (a Windows install is running), `dropping` (files are being copied in) and `clipboardSync` (the per-VM clipboard policy, true unless turned off); `installing` and `dropping` are absent unless true. The host refuses `audio enable` unless the request carries `testMode: true`, because Windows sound turns on Test Mode, which weakens driver signature checks; `openvmctl audio enable --test-mode` is how a person says so, and the app asks first. The ops that change a VM's life (`start`, `stop`, `suspend`, `resume`, `delete`, `set`) hold its slot while they run: a second one answers `<name> is busy: <op>`. A `stop` is let through a `start`, because it is how a boot is cancelled.

Name rule: 1–64 chars of `[A-Za-z0-9_-]`, first char alphanumeric (so CLI flags never
collide). Record ids are `UUID().uuidString` values, generated at create time.

## Disk-backed lifecycle readiness

First boot installs Alpine and exports a matching installed kernel/initramfs pair to the daemon's
artifact receiver (`OPENVM_ARTIFACT_PORT`, default 8124). Each install boot gets a fresh random token on the
kernel command line (`openvm.artifact-token=`); the guest sends it in `X-OpenVM-Token`, and the
receiver refuses any upload without it, and any connection from outside the vmnet subnet
(192.168.64.0/24). The receiver listens on every interface (the vmnet gateway does not exist until
the guest is up), so the token is what keeps a LAN peer from replacing a VM's boot kernel. Subsequent boots use that pair with the
installed ext4 root rather than the smaller netboot initramfs. Disk-backed `start` waits for an
OVMC echo round-trip from the guest agent before replying successfully; no agent log marker is
required. Guest console output remains available in `<OPENVM_HOME>/<name>.console.log`.

`stop` asks the guest agent to shut down (`suspendRequest {op: "shutdown"}`), because the framework's power button reaches neither guest. It waits up to 120 seconds when the agent agrees, 30 when the agent refuses, and 2 when no agent answers, then forces the VM off, including when the graceful request fails. It confirms the VZ state is stopped before releasing the live VM and updating the registry. A failed stop retains the live VM for retry. Forced shutdown may lose unsaved guest data.

`suspend` pauses the live guest (Virtualization.framework pause) and moves the record to the
`suspended` state; `resume` unpauses it (`suspended` → `running`). Both require this daemon to
hold the live guest. A host restart orphans the guest (it dies with the process), and the next
host start records every `running` or `suspended` VM it finds as `stopped`. A paused guest answers no guest-channel
traffic (ping, clipboard, file). The guest flushes before it is paused, and a resume pushes the clock again, re-mounts the shares and re-applies the display mode and scale.

## Replies: `vmReply` (type 7)

Body map: `{"op": <echoed>, "status": "ok"|"error", "result": {…}}`.

* `status: ok` + `result` keys depend on the op: `message` (create/start/stop) or a
  `vms` array of maps (list, info): name, state, uuid, cpus, memoryMB, diskPath.
* `status: error` + `result.message` = the error text (e.g. `badTransition`,
  `nameExists`, `nameInvalid`, `notFound`, `unknown op`, `body not a CBOR map`).

`openvmctl clipboard push <name|uuid>` reads text from the macOS general
pasteboard and invokes `clipboard-write`. `openvmctl clipboard pull` invokes
`clipboard-read` and writes the returned text to the macOS pasteboard. These
operations need a logged-in guest desktop session. On Linux that also means `wl-clipboard`
or `xclip`, which the install adds with an XDG autostart hook that publishes the
session's display environment to the agent. Windows guests log on at every boot.

`openvmctl file push <name|uuid> <host-path> [guest-name]` and
`openvmctl file pull <name|uuid> <guest-name> <host-path>` transfer files in
64 KiB chunks. The guest agent stages files in `/tmp/openvm-share` on Linux and `%TEMP%\openvm-share` on Windows; guest names
are basenames and cannot select arbitrary guest paths. Transfers are limited to
1 GiB and incomplete uploads stay hidden as temporary files until commit. A
successful push atomically replaces a same-named guest file; a pull atomically
replaces the host destination.

`openvmctl share add <name|uuid> <host-dir> [guest-dir]` exports a host
directory to the guest and mounts it; `share list` shows the record's shares;
`share remove` unmounts it. Shares ride Virtualization.framework's virtio-fs
device (tag `openvm`); every VM is created with it, and the daemon replaces the
device's share set when a share is added to or removed from a running VM, so no
restart is needed. The guest agent bind-mounts the share's directory onto the
guest path; on Windows every share is a directory of the `Z:` drive. The daemon writes a probe file into the shared directory, has the
guest read it back through the mount, and deletes it again, so a reported mount
is a proven round trip. Shares of a stopped VM are mounted at the next boot, and
re-bound after a resume. Share changes are refused while a drop is running, because
replacing the share set breaks reads in flight.

## Guests that stop on their own

The host listens for the framework's end-of-guest report, so a guest that shuts itself down (the
Start menu, `poweroff`, a crash) is recorded as `stopped` without any command, and its drops and
display mode are cleared. A report counts only for the boot it came from. A VM is visible to the
host from the moment it starts to boot, including the Windows install: until its agent answers,
channel operations refuse it with "still booting", and a window can already show its screen.

## Host sleep

The daemon watches the host's power notifications. Before the host sleeps it
asks every running guest to flush (`suspendRequest`, type 16) and pauses it;
the sleep is acknowledged only after that, because the system goes to sleep
anyway after 30 seconds if nobody acknowledges it. After the wake the guests
are resumed and the channel-side state is re-established: the clock and the
timezone are pushed again and the shared folders are re-mounted. A guest the
user suspended stays suspended; a guest without a live channel (the daemon was
restarted) is left alone. The `suspend` op uses the same flush, so a user
suspend and a host sleep take the same path into the guest.

## Echo and errors (channel plumbing)

`echoRequest` (3) → `echoReply` (4) with the same body: liveness round-trip.
On the daemon side, an unknown type gets `error` (5) `{'errno': 1,
'message': …}` (`ErrNo` unknownType/badPayload/unsupportedVersion = 1/2/3).
`badPayload` errors use correlation id 0 (the envelope could not be decoded).

## Registry file (host-side state)

The only persisted state: `<OPENVM_HOME>/vms.json` — a JSON array of
VM records (`docs/vm-records.md`); saved atomically, directory
created lazily on first write. Missing file = empty list. Real guest boots stream the
guest console to `<OPENVM_HOME>/<name>.console.log`.
`OPENVM_HOME` override is what the smoke test uses for a hermetic run.
