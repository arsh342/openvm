# Windows guests

What Windows guests depend on, and the faults behind those choices. Read this before
changing the agent's socket code, the guest power settings or the stop path.

All of it was measured on Windows 11 ARM64 with virtio-win 0.1.302 under
Virtualization.framework. The agent's trace build (`OPENVM_AGENT_CFLAGS=-DOPENVM_AGENT_TRACE`)
logs a heartbeat and every display and power event; the guest's `System.evtx`
can be read off its disk from macOS.

## Modern Standby froze the guest

**Symptom.** About 5.5 minutes after the last activity the channel went
intermittent: connect timeouts, with the VM's CPU near 0%.

**Cause.** The guest's platform is S0 Low Power Idle. Turning the display off
enters Modern Standby, and everything in the guest stops:

    06:16:26  display off, Kernel-Power 506 (enter standby)
    06:19:14  agent heartbeat gap 150 s (5 s expected)
    06:20:44  Kernel-Power 507 (exit standby)

Each incoming connection wakes it briefly, which is why some pings still passed.

**Fix.** `SetupComplete.cmd` sets `monitor-timeout-ac 0`, and also the standby and
hibernate timeouts, because the host owns sleep. With these: no 506 events, and no
missed ping after boot in 14 minutes.

## `stop` was a power cut

**Symptom.** `Kernel-Power 41` after every `openvmctl stop`. A print job that had
reached `lp` but not `done` was printed again on the next boot.

**Cause.** `GuestShutdown` gave a guest 2 s, then forced it off. A longer wait
does not help: `requestStop()` never reached Windows (no power event in its log,
forced off after 130 s). Windows on other ARM virtual platforms has the same gap,
since the power-button device has no Windows driver (cloud-hypervisor #7929). That
this is the mechanism here is inferred, not measured.

**Fix.** The daemon asks the agent (`suspendRequest {op: "shutdown"}`), which calls
`InitiateSystemShutdownExW`. A stop now takes 4-10 s and logs `Kernel-Power 109`.
Forcing remains the last resort and is logged. If no agent answers, the stop still
ends in a forced power-off.

openVM's former Alpine guests had the same fault, hidden by ext4's journal: logging forced stops
showed every one was forced. The Linux agent runs `poweroff` for the same request (3-4 s).

## viosock: accept(), select() and FIONBIO

`accept()` must not pend in the driver: 0.1.302 has a lost wakeup there
(virtio-win #1684; fix #1685 unmerged at the time of writing) and the listener
then hangs for good. **This was not the cause of the symptom above**: in the
traced 16-minute run `accepted` kept rising after each freeze, and 240 sequential
pings did not trigger it. Those pings were serial, so that does not clear it. It is
adopted because upstream measured it on this driver and a host that polls is
exposed to it, following the workaround in FuturFusion/vsock#3 (0 of 40 boots lost
the channel, against 9 of 15).

So the listener is non-blocking, and the agent polls `accept()` every 50 ms. Two
traps around that:

* **`select()` is no substitute.** It misses connections queued behind the first
  (`bSetBit` is dropped), and cancelling it can bugcheck (#1692).
* **`FIONBIO` can only turn non-blocking on.** `VIOSockSetNonBlocking` ignores its
  argument, so accepted sockets inherit non-blocking mode and keep it. A `recv` that
  says "would block" means "not yet", not "gone". Treating it as a disconnect failed
  50 of 84 pings, so `sock_send_all` and `sock_recv_all` wait, up to 30 s of silence.
* A non-blocking `accept()` must ask for no peer address, or a connection the peer
  already reset fails with `WSAEINVAL`.

Drop all of this once a driver release carries #1685.

## virtio-fs: reading large files, and replacing the share set

**Reads from a virtio-fs share can fail with error 999.** viofs 0.1.302 can present a
read in the wrong process, so it never reaches the device and fails with an in-page
error (virtio-win #1633, #1659). The fix was merged on 2026-10-26 and is in no release
yet. `CopyFile` hits this often: error 999 on the sixth of a run of 200 MB drops, and a
run with it also hung the whole guest. A 1 MiB `ReadFile` loop hits it less, but does
hit it: one 2 GiB drop failed that way. So the drop helper retries the read at the same
offset, which is safe because nothing was read. In 15 drops the retry fired in 2, and
every copy matched its source by SHA-256 or `cmp`. The agent logs the retries as
`drop finished: ... read retries`.

Apps reading from Z: have no such retry, so a large copy made in the guest can still
fail until a virtio-win release with the fix is pinned. Upstream also describes, from
the code only, a case where the same fault writes a read into the wrong process
without any error. We have not seen it.

**Replacing the device's share set breaks reads in flight.** A `share add` during a
drop failed the copy on Linux and Windows alike. Apple's header says nothing about
this. So dragged files live under a `drops` share present from boot, and share
changes are refused while a drop runs. A user's own open files in one share
in another share are at the same risk while they are being read, since that is what
happened to the drop, whose `drops` share was not the one being changed. Whether a file
that is open but idle survives is untested: it needs a program running in the guest.

## Children of the agent need deadlines

The agent serves one request at a time, so a child that hangs stops ping too.
`read_child` bounds helpers to 15 s and `printers.ps1` to 45 s.

While `printers.ps1` runs, which takes several seconds, other channel ops can time
out at the 2 s connect limit. The bridge therefore syncs only when the host's list
changes and once per boot; re-syncing on every resume made captures fail right
after a resume.

## The first minutes of a new install

`start` returns while Windows is still in OOBE, on a temporary user, and OOBE ends by
signing out and restarting. Until the real desktop arrives (about 7 minutes), anything
needing the session can fail with "no user is logged on", and a shutdown can be
refused. A guest that refuses gets 30 s before it is forced off. Test on the settled
desktop: a check that passes in this window may be talking to the temporary session.

## Sound

The guest has a virtio-sound device with an output stream. Other Mac VMs give Windows
an HD Audio device, which Windows drives itself, but Virtualization.framework offers
only virtio-sound, and virtio-win has no driver for it (checked 2026-11-05).

`openvmctl audio enable <vm> --test-mode` installs the `viosnd` driver from the
`dev` release of Droid-VM/gunyah-guest-drivers-windows. `tools/build/mk-windows-media.sh`
pins that zip by SHA-256 and puts it in `C:\openvm\sound`. The release is a moving
prerelease: if it changes, the media still builds, with a warning, and cannot turn
sound on. `tools/windows/sound.ps1` does the work and logs to
`C:\openvm\sound\sound.log`.

The driver is signed by `DroidVM Test`, so enabling sets `testsigning` and adds that
certificate to Root and TrustedPublisher. We do not hold its private key: whoever
does could sign code this guest would trust. Removing Test Mode needs a Microsoft
signature, and that needs an EV certificate and a Hardware Developer Program account,
which is set up for organizations. Cross-signing ended, even with Secure Boot off.

`pnputil` refuses the package with "publisher ... not established as trusted" in the
boot that turns test signing on, so a scheduled task installs it on the next boot.

Tested on a fresh install on 2026-11-05: off by default; on after enable and a
restart; a person heard the boot sound, and 120 s of playback, which took 120.16 s
and was clear; off again after disable. Latency is unmeasured.
`tools/test/windows-smoke.sh` repeats the flow, and proves the tone by the Mac's output.

The other driver, 317764920/viosnd, also played here, but needs `EndpointRole` set
to 0 under the device's `Device Parameters` key, or it stops with Code 10.

USB audio is not an option, since Virtualization.framework emulates only keyboard,
pointer and storage over USB. RDP's remote audio works only inside an RDP session.

## The agent answers one request at a time

Anything slow in a handler blocks every other request, and a request that cannot connect
within 2 seconds fails. `printers.ps1` did this after a restart: `audio disable` failed with
`connect timed out` while the log showed the sync finishing. So the sync runs on its own
thread and answers `pending`. `audio enable` and `disable` still hold the agent while their
script runs.

## Display scale

Windows has no documented way to change scale without a sign-out. The agent uses what
the Settings app uses: `DisplayConfigSetDeviceInfo` with the undocumented type -4,
which counts steps from the recommended scale. A Windows update could change that, so
the agent trusts only the DPI the monitor reports afterwards.

Windows caps scale by desktop size: measured 150% at 1600x900, 175% at 1920x1080, 250%
at 2560x1600, and 200% is allowed at 2048x1536.

`viogpudo` sizes its framebuffer when it starts, from the largest mode it knows, with a
16 MiB floor, and refuses anything bigger. That is 4,194,304 pixels: 2048x2048 worked
and 2600x1620 did not, so a 14-inch Mac's 3024x1964 failed. `SetupComplete.cmd` sets
`PersistentDispMode0Width` and `Height` to 5120x2880 in the driver's key, which makes
room from the next boot. Guests installed before that keep the limit.

## The smoke test

`make windows-smoke ISO=<windows-iso>` installs Windows through `openvmd` and exercises
clipboard, files, shares, printing, display, drag and drop, suspend, sound and the time
zone, then reads the guest's disk after shutdown. It takes about 30 minutes and is not
part of `make check`. Printing uses a fake CUPS. A share is proved when `share add`
succeeds: the guest has to read back a random probe file through the share.

## Still unexplained

* One blue screen: bug check 0x3B, `virtiofs.exe` current, WinFsp addresses in the
  dump. It happened during the first drop runs, when each drop replaced the share
  set and used `CopyFile`. 40 rapid share swaps alone did not repeat it, and #1698
  needs a second device, so it does not apply. It has not recurred since the redesign
  (13 large drops), but it was never reproduced, so this is "no longer seen", not
  "fixed".
  The race in #1633 runs in the driver with `virtiofs.exe` as caller, so it is a
  candidate, not a finding.

* `printers.ps1` times out on the first sync after a fresh install, every time,
  then succeeds on the retry about 20 s later. Earlier the same step failed with
  "the specified driver does not exist", so the Print to PDF driver is probably not
  ready yet. Not confirmed; harmless, since the bridge retries.
* One boot failed to bring the agent up within 180 s, right after a forced stop.
  It has not recurred in the boots since `stop` became clean. That the forced stop
  caused it is a guess.
* The first boot comes up at 1024x768 (viogpudo's default), not the 1920x1080
  scanout. Later boots keep the last mode.

## Building the install media

`tools/build/mk-windows-media.sh` turns the user's ISO into a raw disk image that boots straight
into an unattended install: a FAT32 boot volume (the boot chain, the BCD, `boot.wim`) and an exFAT
data volume (`install.wim`, which is 7.6 GB and cannot live on FAT32). It needs three things the
app cannot assume a Mac has, and handles each:

* **The UEFI applications and the Windows agent** are built when the payload is built
  (`tools/build/mk-payload.sh`, which needs clang, lld and zig) and shipped prebuilt
  (`OPENVM_PREBUILT`). A payload built where those tools are missing has no Windows part, and the
  task says so.
* **wimlib** does four things: read the Windows edition and language out of `install.wim`, and add
  the WinPE payload to `boot.wim`. They are one script, `tools/build/wim-job.sh`, because they
  depend on each other's results. It runs on the Mac when the Mac has `wimlib-imagex`
  (`OPENVM_WIMLIB`), and otherwise in a **helper VM**.
* **The helper VM** is a short-lived Alpine guest (`openvm.job=wim` on its kernel command line).
  wimlib is GPL, so openVM never ships it: the guest installs it from Alpine's *community*
  repository (it is not in `main`; 1.14.4, 466 KiB) each time, then runs the job script on two
  shared folders, the job folder (read-write) and the mounted ISO (read-only), writes `ok` or
  `error: …` to `status` in the job folder, and powers off. Nothing is installed on the Mac.
  `openvmd --wim-job <job-dir> <iso-root>` (and the app binary) runs one; it takes no host lock
  and its own artifact port, so it works beside a running host.

**Measured** with the real Windows 11 ARM64 ISO (26300, en-GB) on an M-series Mac, with the
download cache warm:

| wimlib from | total time | edition | `boot.wim` |
|---|---|---|---|
| the Mac (Homebrew) | 35 s | image 3, en-GB | 642,851,057 bytes |
| the helper VM | 43 s | image 3, en-GB | 642,851,579 bytes |

The two `boot.wim` files hold the same 63 files under `/openvm`, and `unattend.xml`,
`image-index.txt` and `winpeshl.ini` are byte-identical; the 522-byte size difference is wimlib's
own metadata. The helper's job itself takes about 15 seconds; the rest is copying the ISO's files.

**Checking the ISO first.** `windows-iso-check` mounts the ISO and reads file names only, so a
wrong download (an x64 ISO, a Linux ISO, an ISO with `install.esd`) is refused in about a second,
with a reason, instead of after the build. The real ISO above is accepted in 1.2 s.

## Sending files to the Mac

`openvm-tools-win.exe --send <path>...` (the "Send to Mac" entry in the SendTo menu, added to the
default profile by `SetupComplete.cmd`) copies files and folders into `Z:\outbox`, the same way the
Linux tool does: built under a hidden name, `.ready` written last, renamed into place. A link
(reparse point) anywhere stops the send. The copy uses the same read-retry loop as a drop, because of
the viofs read faults noted above.

Measured on a real Windows guest (`docs/evidence/windows-smoke-send-2026-11-06.txt`): a 2 GiB file went
Desktop to Mac byte-identical in 12 s, and the received file carried the quarantine mark. Not yet
measured: a 12 x 200 MB tree, and the SendTo menu itself by hand (the smoke starts the helper through
the agent, not through Explorer).

## The account

The wizard asks for a user name, a password, and whether to sign in automatically. The account is made
by the answer file, and `SetupComplete.cmd` then makes sure it is in Administrators, by the group's SID
and with the computer's name in front of the user's, and writes the group's members to
`C:\openvm\setupcomplete.log`. Without a wizard the script's defaults stand: `openvm` / `openvm`.

Guests installed before this were left with no usable administrator: the computer and the account were
both called `openvm`, and `net localgroup administrators` listed only the disabled built-in
`Administrator`, so an elevation prompt had nobody to offer. Windows does not allow a user named like the
computer, which is why the computer is now `OPENVM-GUEST`. That this collision is what stopped the account
joining the group is the likely reading, not a proven one. A real install with this fix has not been
checked yet: `make windows-smoke` now fails if the account is not an administrator.

The password goes from the wizard to the media script through its environment, never its command line.
It is plain text in the answer file on the install media, which the host deletes after the install. With
automatic sign-in Windows keeps it in the guest, in a form that can be read. Without it, the guest starts
at the sign-in screen, and what needs a session (clipboard, drops, display) waits until someone signs in;
that path has not been run yet.
