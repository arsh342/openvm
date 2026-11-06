# GUI notes

What was measured about the VM window, and what is still to be checked by hand. Facts are
marked **measured** (with how) or **to check**.

## The window

* **Measured.** `VZVirtualMachineView` shows a guest only if the live `VZVirtualMachine` is in the
  same process, and Virtualization.framework offers no framebuffer API. So the app hosts the
  VMs (`OpenVMHost`), and the window is built on that view.
* **Measured.** The framework allows one scanout per virtio graphics device, so a guest has one
  display. The window can move between Mac displays and go full screen on any of them.
* **Measured.** A window left to AppKit's default placement opened 1249 wide for a 1280 request:
  AppKit squeezed it to the screen's right edge (221 + 1249 = 1470). The window is now centred
  on first use and keeps its frame after that (read back with the window list: 1280 x 748, the
  748 being 720 plus the title bar).
* **Measured.** `openvm://vm/<name or uuid>` opens a VM's window. It names a VM and carries no
  action, so following one cannot change anything.

## Reported by the owner

* **Reported 2026-11-06, Linux guest (srv1), Retina Mac.** Typing and the pointer work inside the
  window. A screenshot from the owner shows the guest's XFCE desktop filling the window,
  titled with the VM's name. Not yet covered: non-US layouts and Option-key characters,
  pointer accuracy measured against targets, and anything on a Windows guest.

## To check by hand (needs a person at the keyboard)

The terminal this was built from has no Accessibility or Screen Recording access, so none of
these could be driven or photographed from there. Check on one Linux and one Windows guest,
and write the result next to each line.

* [x] Typing reaches the guest (reported, Linux). [ ] Still to check: a non-US layout and the
      Option-key characters.
* [x] The pointer works (reported, Linux). [ ] Still to check: it lands exactly where it is
      clicked at scale 2, and on Windows.
* [ ] Cmd+C, Cmd+V, Cmd+W, Cmd+Q and Cmd+Tab: what each does windowed and in full screen.
      Cmd+Q must not quit the app silently while a guest has focus.
* [ ] A menu key equivalent does not swallow a guest shortcut.
* [ ] The boot screen shows through a Windows install.
* [ ] A 12-minute idle stays responsive (past Windows' Modern Standby timer of about 5.5
      minutes).
* [ ] The window title follows the state (Starting, Paused, Stopped), and the cover with a
      Start button shows for a stopped VM.

## Resize and scale

* **Measured 2026-11-06, Linux guest, Retina Mac.** A guest started under a 1280 x 720 point
  window came up at 2560 x 1440 pixels, read from the guest's own screen capture
  (`openvmctl display capture`, then `file pull`): the window's size in points times the
  backing scale of 2.
* The fit is requested when the window resizes (live, zoom and full screen all arrive as
  resizes), when its backing scale changes (moved to another display), and once when the
  guest becomes ready. It is sent 250 ms after the last change, one at a time, latest size
  only.
* A scale Windows refuses ("Windows allows at most N% at this size", and the agent's other
  scale refusals) steps down to the highest one it allows. Any other failure, such as an
  unreachable guest, is tried once.

To check by hand: drag the window to a new size, wait a second, and run
`openvmctl display capture <vm>` then `file pull`; the capture's pixel size should be the
window's size in points times 2. Also try full screen, and moving the window to a
non-Retina display if one is attached. Record how long the guest takes to settle after you
stop dragging.

### What went wrong the first time, and how it was found (2026-11-06)

The first build did not follow the window. The owner's screenshot of a maximized window showed
the guest drawn at its old size in the bottom-left corner, with dark bars above and to the
right, and the guest's own capture was still 2560 x 1440. Three separate faults, each found by
measuring, not by guessing:

* **The machine view did not follow its window.** A trace of the running app showed the
  window's content view growing (1280, 1282, 1466, 1470 points wide) while the machine view
  stayed at 1280 x 721. The fit reads the view's size, so it computed the old mode and skipped
  it. A stock `VZVirtualMachineView` has `translatesAutoresizingMaskIntoConstraints` off, and
  the fix pins it (and the cover) to the window with Auto Layout constraints. After that the
  trace shows view and container equal. *Not explained:* four isolated probes (a plain view, a
  `VZVirtualMachineView`, one with a machine attached, one animated through zoom and full
  screen) all followed their container under autoresizing, so the exact mechanism in the
  running app is unknown. The pin is verified in the running app, not derived.
* **The first fit of a new guest was refused.** The guest agent answers before the desktop
  session exists (`cat: can't open '/run/user/1000/openvm-bus'`), so the guest cannot take a
  mode yet. Nothing asked again. A refused mode is now retried after 1, 2, 4, 8, 15 and 30
  seconds, and a newer size restarts the count.
* **The guest's display server rounds a width down to a multiple of 8.** Asked for 2940, the
  Linux guest held 2936, and the host rejects a mode that differs from the one asked for
  (`X holds 2936x1630, not 2940x1630`), so retrying could never succeed. Widths are now rounded
  down to a multiple of 8 before they are asked for. Heights have held exactly so far.

Verified afterwards in the running app: every fit succeeded, the view equalled its container,
and a full-screen window (1470 x 923 points) gave a guest of 2936 x 1846 pixels.

## The VM list

* The list window opens at launch, from Window > Library (Cmd+0), and when the Dock icon is
  clicked with no window open. Closing it does not stop any VM.
* Each row offers only what its state allows: a stopped VM can start or be deleted, a running
  one can open, pause or stop, a paused one can open, resume or stop, and while the host is
  doing something to a VM the row offers only to open it. A running or paused VM cannot be
  deleted, and deleting asks first, naming the disk that is lost.
* **Toolchain limit.** Under the Command Line Tools, SwiftUI's `@State` is a macro whose plugin
  is missing, so the app avoids property-wrapper macros (the pending delete lives in the model,
  not in a `@State`). With Xcode's toolchain this limit does not apply, but then a contributor
  without Xcode could not build the app.
* **Measured.** A Unix socket path is limited to about 104 characters on macOS. A home
  directory with a longer path makes the host fail to start with "socket path too long", and the
  app shows that in its startup alert.

## The menu-bar icon, the Dock icon and quitting

* The menu-bar icon opens a popover with every VM and one button each (Start, Open or
  Resume), a way back to the library, and Quit. It is how a running VM stays reachable with
  every window closed.
* **Closing a window never stops a VM.** With a window open the app is an ordinary Dock app.
  With none open and a guest running, the Dock icon goes and the app lives in the menu bar;
  opening any window brings the icon back.
* **Quitting stops every guest**, so it asks first and names what would be lost: the running
  guests (a paused one counts, because it is held in memory, not saved), a Windows install in
  progress (it starts over), and files still being copied in. Confirming asks every guest to
  shut down at once, forcing off only those that do not, before the app exits. With nothing
  running, it quits at once.
* `openvmctl stop-all` does the same shutdown from the command line.
* **Measured** on a real Linux guest in its booting state: `stop-all` cancelled the boot, the
  waiting `start` reported "cancelled", the VM returned to stopped with no activity, and it
  could be started and cancelled again.

To check by hand (the terminal cannot press these): the popover opens from the icon and each
button does what it says; Cmd+Q with a guest running shows the dialog, Cancel keeps
everything, and Shut Down and Quit shuts a guest down cleanly (on Windows, no Kernel-Power 41
afterwards); closing the last window with a guest running removes the Dock icon, and the
menu-bar icon brings a window back; host sleep with a window open pauses and resumes.

## The toolbar and settings

* **Toolbar** (VM window): Start or Shut Down, Pause or Resume, Full Screen, Share Folder and
  Settings. Which are live follows the VM's state: a stopped VM can only start, a booting one can
  only be cancelled, and while the host is busy with a VM the power and pause buttons are off.
  Share Folder asks for a folder and says the guest can read and change what is in it.
* **Settings** (toolbar, or the gear on a row in the library, which is the only way to reach a
  stopped VM's): CPUs and memory, time zone, shared folders, and for Windows, sound.
  * CPUs and memory are read when the VM starts, so a running VM shows them greyed out with the
    reason. The choices come from `host-info`, so only what this Mac can give a VM is offered
    (CPUs 1 to 32 at most, memory up to what the framework allows).
  * The time zone applies the next time the guest starts or resumes.
  * Windows sound turns on Test Mode, which weakens driver signature checks, trusts a
    third-party certificate and puts a watermark on the desktop. The app shows all of that and
    sends nothing until the person agrees, and the **host** refuses `audio enable` without
    `testMode: true`, so no other client can switch it on silently either.
* **The clipboard toggle is not here yet.** The per-VM setting exists on the host
  (`set --clipboard-sync on|off`, and every row carries it), but nothing reads it until the
  clipboard sync itself lands, so the toolbar and settings do not show a control that would do
  nothing.
* **Measured.** `host-info` first reported 64 CPUs (the framework's limit) while `set` rejects
  more than 32, so the settings would have offered choices the host refuses. The two now share
  one ceiling, with a test.

To check by hand: the toolbar buttons enable and disable as the VM starts, pauses and stops;
Share Folder, Settings and the Windows sound consent dialog behave as described; changing the
memory of a stopped VM takes effect at its next start.

## The creation wizard

File > New Virtual Machine (Cmd+N), or "New VM…" in the library. It does nothing a person could not
do with `openvmctl`; what it adds is the order, the checks before each step, and the cleanup.

1. **System.** Linux or Windows 11. Choosing resets the defaults: Linux 4 CPUs, 4 GB, 32 GB disk;
   Windows 4 CPUs, 8 GB, 64 GB disk. The suggested name is taken only if it is free
   (`linux`, `linux-2`, …).
2. **Source.** Linux: the Linux files, fetched with live progress if they are not there yet. Windows:
   the person's own ISO, checked at once by `windows-iso-check` (an x64 ISO, a Linux ISO or an ISO
   with `install.esd` is refused with the reason, and Continue stays off). With no wimlib on the Mac
   the media is built in a helper VM, which needs the Linux files, so those are offered here too.
3. **Size.** Name (valid, and not already used), CPUs and memory within what this Mac allows, disk.
   Continue is off, with the reason, if the disk is too small for the system, or the Mac does not
   have the free space: Windows needs about 42 GB (22 GB for the media while it is built, about
   20 GB for Windows), Linux about 4 GB.
4. **Summary.** For Windows it says the guest has a local account `openvm` with the password
   `openvm`, to be changed after setup.
5. **Run.** Windows: build the media (progress is the build's last line), create the VM with it.
   Both: create, open the VM's window so the install can be watched, start. The wizard is not modal.

**Cleanup is the point of the design.**

* **Cancel during the media build** cancels the task. The host stops the script and everything it
  started, and deletes the half-written image. Cancel waits until that has finished (it takes a few
  seconds: the ISO and the 22 GB image are unmounted first), so a new run with the same name never
  meets the old one's cleanup. The wait is bounded.
* **Cancel during the install** stops the VM (which cancels a boot in progress), waits until it is
  stopped, and deletes it. The host deletes the install media with the VM, but only a file inside its
  own `media` folder, never one a person passed in by hand.
* **A failure after the VM exists keeps it**, with the host's message (including the console tail),
  and offers to delete it. A failed media build makes no VM and leaves no image.
* Once a Windows install has finished, the host deletes the install media (it was about 22 GB).
* Closing the wizard window mid-run asks first, because it cancels the run.

**Measured on real hosts** (`OPENVM_E2E=1 make test`; these start a real `openvmd`):

* Cancelling a Linux install while it boots left no VM and no disk folder (1 s).
* Cancelling a Windows media build with the real ISO, while the image existed and the ISO and image
  were mounted, left no media file, no attached image and no VM (4 s).
* Killing the media script used to leave the ISO and the image attached. It now stops on SIGTERM and
  runs its own cleanup, which is what cancelling relies on.

To check by hand: the pages and buttons behave as above (the terminal cannot drive them); the ISO
chooser opens and accepts only `.iso` files; closing the window mid-run asks.
