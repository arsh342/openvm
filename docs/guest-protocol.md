# Guest protocol (OVMC)

Version 1. This document is the contract for the OVMC channel between the host
daemon (`openvmd`) and the guest agent (`openvm-tools`). The framing and message
contract are transport-independent. The current guest transport is Apple's
`Virtualization.framework` virtio-socket device: the guest agent listens on
vsock port 52 and the host connects to it. The conformance suite in this
repository is executable proof of the frame and message rules stated here.

## Frame

All traffic on an established channel connection is a byte stream of frames:

```
 0               4        6        8       10              14         14+len
 ┌───────────────┬────────┬────────┬───────┬───────────────┬──────────┐
 │ "OVMC"        │ ver    │ type   │ flags │ length        │ payload  │
 │ 4F 56 4D 43   │ uint16 │ uint16 │ uint16│ uint32        │ …        │
 └───────────────┴────────┴────────┴───────┴───────────────┴──────────┘
```

Every integer is big-endian. `length` counts payload bytes only.

Receiver rules, in order — the first violation stops the connection:

1. Magic must be `4F 56 4D 43`, else **stop** (resynchronisation is not attempted).
2. `ver` must be `1` (the version both sides currently speak), else **stop**.
   Version negotiation is at the handshake layer (below), not the frame layer.
3. `flags` must be `0` in version 1, else **stop**.
4. `length` must be ≤ 1 048 576 (1 MiB), else **stop**. File transfers use
   bounded chunks so each file message stays within this frame limit.
5. A header-valid frame whose payload violates the message rules is answered
   with `error`: `badPayload` for malformed CBOR, `unknownType` for a type
   outside the catalogue, `unknownType` again for reply types sent to the
   answering side (only the opener drives). Unparseable bytes are never
   answered with a decode of their own — the reply is always a fresh
   `error` envelope carrying the correlation id `0`.

A partial frame simply waits for more bytes. Under any of the stop conditions
the connection is closed immediately; the peer must assume it said something
the other side refuses to parse and make no automatic retry.

## Message

The payload is a [CBOR](https://www.rfc-editor.org/rfc/rfc8949) map. The
subset spoken: no floats, no tags, no indefinite-length items; map keys are
text strings; the size cap from the table above applies to every length
argument inside the payload, not just the frame.

One reserved key: `"id"` — the correlation id (uint). It is appended **last**
in the wire map; a receiver strips it and the replier appends it back (so a
reply is self-identifying by id even when body keys differ). Encoders must not
rely on key order except for `"id"` being last; decoders must accept any
order (the deterministic encoder is only for golden-conformance tests).

Catalogue — version 1. **Append-only**: a type number is never reassigned or
reused; new messages get the next free number; receivers must ignore unknown
body keys.

| type | name   | body keys                                                             | reply |
|------|--------|-----------------------------------------------------------------------|-------|
| 1    | hello        | `product` (text), `version` (uint)                          | helloReply |
| 2    | helloReply   | `accepted` (bool), `version` (uint)                         | — (any reply → error) |
| 3    | echoRequest  | any (echo payload)                                          | echoReply, same body |
| 4    | echoReply    | any (echo payload)                                           | — |
| 5    | error        | `errno` (uint), `message` (text)                            | — |
| 6    | vmRequest    | `op` (text), `args` (map)                                   | vmReply |
| 7    | vmReply      | `op` (text), `status` (text), `result` (map)                | — |
| 8    | clipboardRequest | `op` (`read` or `write`), `text` (text, for write)       | clipboardReply |
| 9    | clipboardReply | `text` (text, for read) or `error` (text)                 | — |
| 10   | fileRequest  | bounded `read`, `write`, or `abort` operation             | fileReply |
| 11   | fileReply    | next `offset`, read `data`/`eof`, or `error`              | — |
| 12   | timesyncRequest | `{epochMs, tz?}` — the guest sets its clock (and zone) from the host | timesyncReply |
| 13   | timesyncReply   | `{}`, `{tz}` or `{error}` — the host clock was adopted         | — |
| 14   | sharedRequest  | `{op: "mount"\|"unmount", name?, path, probe?}` — the guest mounts a shared folder | sharedReply |
| 15   | sharedReply    | `content` (the probe file read back), `location` (Windows), or `error` (text) | — |
| 16   | suspendRequest | `{op: "quiesce"\|"shutdown"}` — the guest flushes, or shuts down   | suspendReply |
| 17   | suspendReply   | `{}` on success or `{error}` (text) when the guest cannot           | — |
| 18   | dragRequest    | `{op: "enter"\|"leave"\|"drop"\|"status", share?: text, items?: [text]}` | dragReply |
| 19   | dragReply      | `{accepted: bool, done?: bool, placed?: [text], bytes?: uint, error?: text}` | — |
| 20   | printerRequest | `{op: "list"\|"sync"\|"jobs"\|"fetch"\|"done"\|"test", printers?: [text], default?: text, job?: text, offset?: uint, length?: uint, name?: text}` | printerReply |
| 21   | printerReply   | `{printers?: [text], jobs?: [{job, printer, size}], data?: bytes, pending?: bool, error?: text}` | — |
| 22   | audioRequest   | `{op: "status"\|"test"\|"enable"\|"disable"}`                        | audioReply |
| 23   | audioReply     | `{running?: bool, device?: text, rate?: uint, state?: text, error?: text}` | — |
| 24   | displayRequest | `{op?: "set"\|"capture", width?: uint, height?: uint, scale?: uint}`, scale 1 to 3 | displayReply |
| 25   | displayReply   | `{width?: uint, height?: uint, scale?: uint, capture?: text, error?: text}` — the mode the guest holds, or the staged capture's name | — |

Error numbers: `1` unknownType · `2` badPayload · `3` unsupportedVersion.

For clipboard requests, `read` is defined to return the guest's current UTF-8 text in
`clipboardReply.text`; `write` replaces it with the supplied UTF-8 `text` and
returns an empty successful reply. If no desktop clipboard backend is available,
the responder returns `clipboardReply.error`. Clipboard text is limited by the
1 MiB frame cap; larger clipboard formats and file references use the file
service. The Linux agent implements these messages through a logged-in XDG
desktop session when `wl-clipboard` (Wayland) or `xclip` (X11) is available;
otherwise it replies with a clipboard error.

File transfer uses a fixed guest staging directory, `/tmp/openvm-share`; the
protocol never accepts an arbitrary guest path. `write` requests carry
`name` (a single safe basename), `transferId` (text), `offset` (uint), `data`
(bytes, at most 65,536 bytes), and `eof` (bool). Chunks are sequential and a
transfer is limited to 1 GiB. The guest writes to a temporary file and exposes
the final name only after `eof` commits it atomically. `read` requests carry
`name`, `offset`, and `length` (1–65,536); replies carry the next `offset`,
`data` (bytes), and `eof`. Either operation can return `error` (text). Names
must match `[A-Za-z0-9._-]+` and cannot be `.` or `..`. `abort` requests carry
`name` and `transferId` and remove an incomplete upload's temporary file; it is
safe if that temporary file is already absent. A zero-length write is valid
only when it commits an empty file. The Linux agent, the Windows agent and the
host CLI implement file message types 10 and 11; the mock guest reports them as
unsupported. The staging directory is `/tmp/openvm-share` on Linux and
`%TEMP%\openvm-share` on Windows — the protocol carries a basename, never a
path, so the two guests differ only in where the fixed directory lives.

For timesync the host is the time authority: the daemon sends `epochMs` (wall
clock, milliseconds) in `timesyncRequest` and the guest agent sets its system
clock from it — the guest never runs its own NTP discipline locally. Pushes
happen when the agent first answers after a boot and right after a successful
resume, and are best-effort: a refusal or timeout (`timesyncReply.error`, or
silence) is surfaced but never blocks a lifecycle operation. The agent applies
the clock with `clock_settime` (it runs as root in the persistent guest) and
answers the error key when it cannot (for example a non-root run). The
optional `tz` key carries an IANA zone name (slash-separated components of
`[A-Za-z0-9_+-]`, each starting with a letter). The Linux agent validates it, requires
the zoneinfo file to exist, and points `/etc/localtime` at it; the Windows agent maps
it to a Windows zone and applies it with `tzutil`. An unknown or malformed zone is
refused with the error key. The host validates the name
first, so a bad zone never reaches the guest. Message
types 12 and 13; the mock guest reports timesync as unsupported.

For printing the host publishes and the guest spools. `sync`
carries the host's CUPS queues (`printers`, optional `default`); the agent makes
one guest queue per name that renders to PDF and removes the ones no longer
listed. On Linux that is a CUPS queue with `openvm-pdf.ppd` and the `openvm`
backend, on Windows the stock Microsoft Print to PDF driver on a file port. A
finished job waits in the guest's spool as `PRINTER--ID.pdf`. Because the host
is the only opener of the channel, the daemon polls: `jobs` lists finished jobs,
`fetch` reads `length` bytes (at most 65536) at `offset`, and `done` deletes one.
`list` reports the guest's queues and `test` prints a page through one. A `sync` that
takes a while answers `{pending: true}`: the guest works in the background and the host
sends the same `sync` again until it gets the result. The Windows agent does this.

The daemon gives up a job (`done`) before it runs `lp`: paper cannot be taken back,
so a guest that vanishes part way means "not printed yet", never "printed twice".

A guest is not trusted with the host's printers. The daemon spools a job only if
it names a printer it published to that guest, is at most 256 MiB, and starts
with `%PDF-`; it then runs `lp` with an argument vector, never a shell. A job
`lp` refuses is kept under `$OPENVM_HOME/printjobs/<uuid>/`.

Both ends are shown in `docs/images/print-linux-guest.png` and
`docs/images/print-windows-guest.png`: the PDFs a guest test page delivered.

Dragged files reach the guest through a read-only `drops` entry in the virtio-fs
device, present from boot. For a drop the host clones the items into
`drops/<share>/` and sends `drop`; the agent copies them to the logged-on user's
Desktop, as that user, in the background, and `status` reports `done`, the names
`placed` and the `bytes` copied. A name in use becomes `name (2)`. `enter` answers
whether anyone is logged on to receive files.

A `suspendRequest` with `op: "shutdown"` asks either guest to shut down: the
framework's power button stops neither (`docs/windows-guests.md`).

For shared folders the transport is **virtio-fs**. Every VM has one
Virtualization.framework virtio-fs device, tag `openvm`, whose root holds one
directory per configured share, keyed by share name (`"s"` + 16 lowercase hex of
SHA-256 of the host path). The host can replace the device's share set while the
VM runs, so shares are added and removed live. The `sharedRequest` body carries
`op` (`mount` or `unmount`), the share `name` (mount only), the guest `path` to
mount on, and an optional `probe` file name. The Linux agent mounts the tag once
at `/run/openvm-fs` (`mount -t virtiofs openvm /run/openvm-fs`) and bind-mounts
`/run/openvm-fs/<name>` onto `path`; the Windows agent reads through the drive
virtio-win's VirtIO-FS service mounts the tag on (`Z:`). On a successful mount
the agent reads the probe file back through the share and answers with its
`content`, which is how the host proves the round trip instead of trusting the
mount command. The Windows agent also answers `location` (`Z:\<name>`): there
every share is a directory of the VirtIO-FS drive and `path` is not used. A failed mount or unmount answers with the `error` key. The agent
validates the name (`[a-z0-9]`), the path and the probe name before it touches
the guest filesystem. There is no network listener and no token: the framework's
device confines the guest to the shared directories, and the host's own file
permissions decide what a guest may change. Message types 14 and 15; the mock
guest reports shared folders as unsupported.

The host's sleep is not silent: before the host suspends a running guest it
sends a `suspendRequest` with `op` `quiesce`, and the guest flushes its files
and answers `{}` (or `{error}` when it cannot). The host only then pauses the
VM, and it resumes the VM and re-establishes the integration state after the
wake. Message types 16 and 17; the mock guest reports the suspend handshake as
unsupported.

The catalogue is complete only to the version(s) both sides share. A newer
implementation must still be able to say "I speak at most version N" — via
`error.unsupportedVersion` — but must never invent types on the wire that the
counterparty has not catalogued.

## Handshake

The opener sends `hello` first. If the other side speaks a greater version it
replies `error.unsupportedVersion` and the opener downgrades to that reply's
stated version (none today: only version 1 exists). The opener may not drive
the channel before the reply. Only the opener sends requests, `hello`, and
`error`; the answering side only replies.

## Behaviour implemented by this repository

* `Sources/OpenVMCore` — the codec (`Frame`, `FrameDecoder`, `CBOR`,
  `Envelope`, `EnvelopeCodec`) plus this catalogue as Swift types.
* `Sources/openvm-mockguest` — the mock guest: speaks OVMC over stdin/stdout,
  answers `hello` and `echoRequest`, refuses reply types with
  `error.unknownType`, exits nonzero without answering anything unparseable.
* `Tests/OpenVMCoreTests` — the conformance suite: golden frame bytes,
  round-trips, header-rejection cases, message rules.
* `tools/test/conformance.sh` — pipes golden byte streams through the built mock
  guest and hex-compares the replies.
* The Linux guest agent carries the implemented channel messages over a vsock
  listener on port 52; the host daemon connects through
  `VZVirtioSocketDevice.connect(toPort:)`. The host clipboard CLI and daemon
  request path use clipboard message types 8 and 9. File push/pull uses
  message types 10 and 11 in bounded chunks and stages files under
  `/tmp/openvm-share` in the guest.
* The Windows guest agent (`tools/guest/openvm-tools-win.c`, with its features in `tools/guest/windows/`) is the same
  channel endpoint for a Windows guest, sharing `tools/guest/ovmc_codec.h` with
  the Linux agent so the wire format cannot drift. It implements `hello`,
  `echoRequest`, `clipboardRequest` (8/9 via the Win32 clipboard, UTF-8 at the
  boundary), `fileRequest` (10/11, staging under `%TEMP%\openvm-share`),
  `sharedRequest` (14/15, the shared-folder mount), `timesyncRequest` (12/13 via
  `SetSystemTime` and `tzutil`), `suspendRequest` (16/17), `dragRequest` (18/19, host
  to guest only), `printerRequest` (20/21), `audioRequest` (22/23) and `displayRequest`
  (24/25).

  For `audioRequest`: On Linux, `test` plays a 3 second tone and
  `status` reports the card, and `enable` and `disable` are refused because sound is
  always on. On Windows, sound is off until `enable`, which needs a restart to finish:
  `state` is `off`, `pending`, `on` or `failed`, and `running` is left out because the
  agent cannot tell.

  It runs as the Win32 service `OpenVMTools` (SYSTEM, auto-start, depends on
  `VirtioSocketWSP`), installed by `tools/windows/SetupComplete.cmd`. The
  transport is the virtio-win `viosock` driver's Winsock provider, which
  `viosock.inf` installs as the `VirtioSocketWSP` service; the agent asks the
  driver for the family number (`IOCTL_GET_AF` on `\\.\Viosock`, 40 if the
  driver cannot be asked), binds viosock's 12-byte `sockaddr_vm`, and retries
  every two seconds until the provider is up. The listener is non-blocking and
  polled, working around driver bugs (`docs/windows-guests.md`). Because session 0 has its own
  clipboard, clipboard requests run the same executable in the console user's
  session (`--clipboard-read` / `--clipboard-write`, over pipes); with nobody
  logged on the reply is an `error`. `suspendRequest` flushes the system volume
  (`FlushFileBuffers` on `\\.\C:`) and answers `error` if it cannot, and `shutdown` calls `InitiateSystemShutdownExW`. The agent
  logs channel state to `C:\openvm\agent.log`.

  `tools/build/build-windows-agent.sh` cross-compiles it for ARM64 on macOS with
  zig's mingw-w64 toolchain. `tools/test/test-windows-agent.sh` compiles the
  syntax-check build, cross-compiles the real one with `-Werror` (when zig is
  installed) and round-trips the codec, so a regression is caught without a
  Windows machine.
