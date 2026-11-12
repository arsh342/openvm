# GUI notes

What was measured about the VM window, and what is still to be checked by hand. Facts are
marked **measured** (with how) or **to check**.

**A note on "Linux guest" below.** Until 2026-11-11 openVM made its own Alpine Linux guest, with
openVM's agent, and most Linux measurements here were taken on it. That guest is gone: Linux now
installs from the distribution's own ISO, with no openVM tools (see "Linux, from an ISO").
What was measured on the Alpine guest is kept as a record, and says so where it matters.

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

* **Reported 2026-11-06, the Alpine guest (srv1), Retina Mac.** Typing and the pointer work inside the
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

* **Measured 2026-11-06, the Alpine guest, Retina Mac.** A guest started under a 1280 x 720 point
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

* The menu-bar icon opens a menu with every VM and the commands for the current one, a way back
  to the library, and Quit. It is how a running VM stays reachable with every window closed.
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

To check by hand (the terminal cannot press these): the menu opens from the icon and each
item does what it says; Cmd+Q with a guest running shows the dialog, Cancel keeps
everything, and Shut Down and Quit shuts a guest down cleanly (on Windows, no Kernel-Power 41
afterwards); closing the last window with a guest running removes the Dock icon, and the
menu-bar icon brings a window back; host sleep with a window open pauses and resumes.

## The menus, the library and settings

* **View, Actions and Devices** are in the menu bar and, as submenus, under the menu-bar icon. One
  piece of code (`MachineMenus`) feeds both, so they cannot disagree.
  * View: Enter or Exit Full Screen.
    Retina Resolution (Best for Retina Display, or Scaled) was removed with the Alpine guest, the only
    guest that took a size from it. Reverse Scrolling and Full Size Display were removed on 2026-11-12: the
    first could not work ("Scroll direction" below), and a Windows guest now always gets the window's full size.
  * Actions: Start or Shut Down (or Cancel Start), Restart, Pause or Resume, and Settings.
  * Devices: Share Clipboard and Accept Files from the VM (ticked when on), and Share Folder.
  * They act on the **current VM**: the one last in front or last chosen under the icon, else a live
    one, else the first. That is what lets them work with the app in the background.
  * Which are live follows the VM's state: a stopped VM can only start, a booting one can only be
    cancelled, and while the host is busy with a VM the power and pause items are off.
  * The only shortcuts are Settings (Cmd-,) and Full Screen (Ctrl-Cmd-F), so a shortcut meant for the
    guest is never taken for a power command. There is no Edit menu for the same reason: Cmd-C and
    Cmd-V must reach the guest, and whether a menu would take them first has not been measured.
  * Only commands that work are listed. There is no screenshot, snapshot or force-stop command yet.
  * Share Folder asks for a folder and says the guest can read and change what is in it.
  * File ▸ Open Virtual Machine lists every VM.
* **Library** (a Settings-style window: a translucent sidebar with search, "All Virtual Machines", each VM with a coloured icon and state dot, and "New Virtual Machine…"; the traffic lights sit on the sidebar). "All Virtual Machines" is a grid of cards, one per VM, with a picture of its screen, its state and the action most
  wanted (Start, Resume or Open) on the card. Click a card to open its window; right-click for Pause,
  Shut Down, Settings and Delete. A dashed "New VM…" card starts the wizard. Choosing a VM in the sidebar shows its page: a picture, its actions as rows, and its details. The picture is the last
  one taken of the guest's screen, kept under `$OPENVM_HOME/thumbs`, so a stopped VM still shows how it
  was left; until there is one the card shows a plain tile with the system's symbol. It is taken when
  the window loses focus or closes, and every 30 seconds while the window is up and the guest runs. A
  blank capture is never kept. *Not yet checked in a real window:* whether the Virtualization view can
  be read this way at all; if it returns black, the cards stay on the plain tile.
* **Creation window**: the same sidebar style, listing the steps (System, Source, Resources, Summary, Install); done steps get a tick, the current one is highlighted. The Back and Next buttons move between them.
* **VM window title bar**: dark and slim, with four round buttons at the right (power, pause, full
  screen, settings) that fade back while the pointer is away. They do what the Actions and View menu items do.
* **Menu-bar icon**: a computer symbol, which follows the menu bar's light or dark look. Its menu lists every VM with the current one ticked, the
  current VM's state and size on a line of its own, then View, Actions, Devices and Settings, then
  Show Library, New Virtual Machine, About and Quit. Choosing a VM makes it current and opens it.
* **Settings** (the Actions menu, or the library, which is the only way to reach a stopped VM's): CPUs and memory, time zone, shared folders, and for Windows, sound.
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
  clipboard sync itself lands, so there was no control for it until it landed (it is in the Devices menu and settings now).
* **Measured.** `host-info` first reported 64 CPUs (the framework's limit) while `set` rejects
  more than 32, so the settings would have offered choices the host refuses. The two now share
  one ceiling, with a test.

To check by hand: the menu items enable and disable as the VM starts, pauses and stops;
Share Folder, Settings and the Windows sound consent dialog behave as described; changing the
memory of a stopped VM takes effect at its next start.

## The creation wizard

File > New Virtual Machine (Cmd+N), or "New VM…" in the library. It does nothing a person could not
do with `openvmctl`; what it adds is the order, the checks before each step, and the cleanup.

1. **System.** Linux from an ISO (where the wizard opens) or Windows 11. Choosing resets the
   defaults: Linux 4 CPUs, 4 GB, 64 GB disk; Windows 4 CPUs, 8 GB, 64 GB disk. The suggested name is
   taken only if it is free (`linux-vm`, `linux-vm-2`, …; `windows-11`, …).
2. **Source.** The person's own ISO. Linux: checked at once by `linux-iso-check` (an x86-64 ISO is
   refused with the reason). Windows: checked by `windows-iso-check` (an x64 ISO, a Linux ISO or an
   ISO with `install.esd` is refused, and Continue stays off). With no wimlib on the Mac the Windows
   media is built in a helper VM, which needs a small download, so that is offered here too.
3. **Resources.** Name (valid, and not already used), CPUs and memory within what this Mac allows, disk.
   Continue is off, with the reason, if the disk is too small for the system, or the Mac does not
   have the free space: Windows needs about 42 GB (22 GB for the media while it is built, about
   20 GB for Windows), Linux from an ISO about 16 GB.
4. **Account** (Windows only). The user name, the password and whether to sign in automatically.
5. **Summary.** What will happen, including what signing in means. The password is never shown.
6. **Run.** Windows: build the media (progress is the build's last line), create the VM with it.
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

* Cancelling an Alpine install while it booted left no VM and no disk folder (1 s; that test went with the Alpine guest).
* Cancelling a Windows media build with the real ISO, while the image existed and the ISO and image
  were mounted, left no media file, no attached image and no VM (4 s).
* Killing the media script used to leave the ISO and the image attached. It now stops on SIGTERM and
  runs its own cleanup, which is what cancelling relies on.

To check by hand: the pages and buttons behave as above (the terminal cannot drive them); the ISO
chooser opens and accepts only `.iso` files; closing the window mid-run asks.

## Clipboard

The clipboard moves **when focus moves**, not on a timer: the Mac's text goes to the guest when the
VM's window becomes the one in front, and the guest's text comes back when it stops being. An idle
guest costs nothing, and neither guest agent needed a change. The decisions are in `ClipboardPolicy`
(pure, tested without a window); `ClipboardSync` does the I/O and runs one transfer at a time.

* **Text only.** Rich text, images and files stay out of this milestone.
* **Only what is new.** The Mac's text is sent only if the pasteboard changed since the last sync, and
  text the Mac gave the guest is never written back (that would replace an image or rich text on the
  Mac with plain text for nothing). Text pulled from the guest does not count as a new Mac copy.
* **Private items stay on the Mac.** Anything marked `org.nspasteboard.ConcealedType` or
  `TransientType`, the convention password managers follow, is never sent. The window's subtitle says
  "Clipboard not shared: it was marked private".
* **512 KiB limit**, half the 1 MiB frame, because the Windows agent's clipboard buffers are half a
  frame (a larger text would work on Linux and fail on Windows). The subtitle says when it is skipped.
* **A guest with no desktop yet** (just booted) refuses the write; that is not an error to show. The
  next focus tries again.
* **Per VM.** Devices ▸ Share Clipboard and Settings ▸ Clipboard turn it off or on, also while the
  VM runs. The setting is the record's `clipboardSync`; a record without it means on.
* **Logged:** each transfer's size and direction on the app's stderr. The text itself never is.

To check by hand (the terminal cannot focus windows): copy in a Mac app, click into the VM window, and
paste in the guest; copy in the guest, click out to the Mac, and paste; copy from a password manager,
click into the VM, and see that nothing arrives and the subtitle says why.

## Dropping files onto a window

Files dragged from Finder (or Photos, Mail) onto a running VM's screen are copied to the guest
user's Desktop. The screen is a `VZVirtualMachineView` subclass (`DropMachineView`) that also
accepts drags, so keyboard and mouse reach the guest exactly as before; no overlay sits on top.

* **Checked first.** `DropSession` applies the host's own rules before anything is sent: 1 to 64
  items, valid names, no two with the same name. A bad drop fails at once, with the reason, and
  copies nothing.
* **One at a time.** The window takes no drop while one is running (the cursor shows no copy), and a
  second one reaching `DropSession` is refused with a message. The host refuses it too.
* **Followed to the end.** The host stages and copies; the app polls `status` once a second, only
  while a drop runs, and stops when the guest says it is done, reports an error, or the VM stops.
  The window's subtitle shows the result; a failure opens a sheet with the guest's reason.
* **Promised files** (Photos, Mail) are written to a temporary folder by the app first, and that
  folder is removed once the copy has finished.

To check by hand (the terminal cannot drag): drop one file, a folder, a file with a Unicode name, a
photo from Photos, and a 1 GiB file on each guest; the guest must keep answering while it copies;
mouse input must still work over the whole screen. Not yet measured: whether the view reports
drag events while the guest has the pointer captured.

## Sending files from a guest

Measured first on the Alpine guest, which is gone; Windows works the same way (`docs/windows-guests.md`,
"Sending files to the Mac"). A guest sends files through the VM's `outbox` share (writable, present from boot). `openvm-send`
(run by the desktop user, from Thunar's "Send to Mac" or `openvmctl drag send`) builds a set under a
hidden name, writes `.ready` last, and renames it into place; the host reacts to that one event, vets
the set (`OutboxRules`), moves it to `~/Downloads/openVM/<vm>/` and marks it quarantined.

Measured on a real Linux guest (`docs/evidence/linux-smoke-send-2026-11-06.txt`): the desktop user can
write through virtio-fs (the host makes the folder mode 0777), the event fires, and a 2 GiB file
arrived byte-identical, 7 s from request to file on the Mac. One earlier run of the same smoke failed
at the start because `openvmctl` found no daemon socket right after the daemon restart; it passed on
the next run and the cause is not found.

## A guest that restarts itself

The framework reports a guest's restart as a stop. The Alpine guest worked around that: its agent
printed `going down: reboot` on the console and the host started it again. That went with the Alpine
guest (record: `docs/evidence/linux-smoke-restart-2026-11-06.txt`). A Linux guest from an ISO has no
agent, so a restart from inside may stop the VM; press Start.

* **Windows needs no help.** A restart from the Start menu comes back by itself, with the VM never leaving
  Running (owner, 2026-11-10; also seen on 2026-11-07 and 08, when Start-menu restarts and two crash reboots all
  kept the VM Running). This was earlier written down as a bug without being tried. Why Windows differs is
  not known; a likely reason is that it resets through the firmware, which the framework carries out as a reset
  and not a stop.

## Where M4 stands (2026-11-12)

The build work is finished. M4 is not accepted yet: the clean-account acceptance run in `docs/manual-checks.md`
needs a person. The screen recording was dropped from the checks on 2026-11-12 (the owner's call: every
feature it would show was checked by hand). Scrolling, the clipboard edge cases, Windows
sound, the files checks and printing on paper passed on 2026-11-12. Known faults:

1. Scrolling in a guest follows the fingers, not the Mac's setting, and only the guest can reverse it (below).
2. A Windows guest gets the window's full size, which scrambles with the released `viogpudo` (0.1.302). The cause
   is measured and fixed upstream in two pull requests (virtio-win 1687 and 1717, issue 1720); until a signed
   release carries the fix, a guest needs a driver built with it. Until 2026-11-12 the app held Windows guests at
   1024 pixels wide instead, with View ▸ Full Size Display to lift the hold; the owner chose the full size always.
3. Windows guests installed before the agent fix have an invisible second display (below). The agent now
   switches it off.
4. A Linux guest installed from its ISO has no openVM tools, so the clipboard, files, printing and clock are not
   shared with the Mac (README, "Create a Linux guest").

## Scroll direction

Scrolling in a guest follows the fingers and ignores the Mac's natural scrolling, so with natural scrolling on
(the Mac's default) it runs the other way. The app cannot change it: `VZVirtualMachineView` takes the scroll
amount from the original event, so neither a flipped copy nor a new event changed what the guest got
(`docs/evidence/scroll-direction-2026-11-12.md`). View ▸ Reverse Scrolling, which tried, was removed. The guest
can reverse it: Hyprland's `natural_scroll`, and in Windows `FlipFlopWheel` on the mouse, each matched the Mac,
sideways too. The Windows agent sets `FlipFlopWheel` = 1 on every mouse when it starts and restarts only a mouse
whose value changed, which applies it without a restart of Windows (`tools/guest/windows/scrolling.c`). It is
always natural, the Mac's default, by the owner's choice: a Mac with natural scrolling off gets a reversed guest.
Linux guests have no openVM tools, so the README says how to set it. A mouse wheel has not been checked.

## Dragging out of a guest: moved to later

Not built, and no experiment was run (decided 2026-11-09). "Send to Mac" already takes files and folders out, and
dragging out would need new code in both agents and an invisible drop target in the guest, a design known to steal
focus and swallow input. Two limits stay: files land in `~/Downloads/openVM/<vm>/` and not where a person would have
dropped them, and a guest installed from its own ISO has no agent, so it has no Send to Mac.

## Known fault: a Windows guest's picture scrambles in its window

The window shows the right colours with the rows misplaced, and only the parts of the screen that change
are redrawn. It starts when the guest's display driver (`viogpudo`) takes over from the firmware; the
logo and "Please wait" are fine.

**Where it is, measured.** Captures of the Mac-side view, returning to 1024x640 between each test size:

| Guest width | What the window showed |
| --- | --- |
| 1024 (x640, six captures; x768 once, by eye) | Clean |
| 1280 | Repeating vertical bands |
| 1536 | Overlapping copies |
| 2048 | Zoomed 2x, left and right halves on alternate rows |
| 3072 | Mostly dark, with fragments |

Those patterns are what reading each row at 1024 pixels gives when the rows are really wider. Windows
itself is right: a capture inside the guest at 2496x1496 was a clean desktop while its window was
scrambled. The guest accepts every size tried. Turning off the 5120x2880 registration did not stop it.

**The cause, measured (2026-11-11).** A trace of the signed `viogpudo` 0.1.302, recorded in the guest
with Windows' own `logman` and decoded with the driver's published symbols, shows the device's reply to
every command (`docs/evidence/viogpudo-mode-change-trace-2026-11-11.md`). On a mode change the driver
unrefs the resource that is still on the scanout, and Apple's device refuses (`ERR_INVALID_PARAMETER`).
The driver then creates the new mode under the same id, and that is refused too
(`ERR_INVALID_RESOURCE_ID`). So the resource on screen stays the 1024x768 one made at boot, with the new
mode's memory attached to it. Scanouts and transfers wider than that are refused, and the Mac reads the
wider memory at 1024 pixels a row. A 1024-wide mode fits the old resource, which is why it is the only
clean width. The fix belongs in the driver: create the new mode under a fresh id, point the scanout at
it, then free the old resource. Built and traced on 2026-11-12 (`docs/patches/viogpudo-mode-change.patch`,
reported as virtio-win issue 1720): the same mode sequence gave no refused command, and 1600x900 drew clean in
the window. Two upstream pull requests, 1687 and 1717, already make this kind of change; both passed the same
test here. Guests still get the scramble until a signed virtio-win release carries the change, so the
1024-wide hold stays.

**Tried, and did not help:**

* Turning off the 5120x2880 registration.
* Turning off the second display (below): 1280 still smeared, and larger sizes gave no capture at all.
* Restarting the device: `pnputil /restart-device` crashes Windows on this guest (below).
* Booting into a large size: with 2496x1496 set, Windows came back at 1024x768, with the app's fit off, and
  again with the host reporting 2496x1496 as the scanout. The driver hard-codes 1024x768 as its preferred mode.

**A patched driver, tried on one guest (2026-11-08).** One byte of `viogpudo` 0.1.302 changed, so the mode
change calls `DestroyFrameBufferObj(TRUE, FALSE)`, under Test Mode and with a self-signed certificate. Pictures are
captures of the Mac-side view. The guest's service path confirmed the patched file was the one running.

| Change, with the patched driver | What the window showed |
| --- | --- |
| 1024 to 1536 | Clean, filling the window (overlapping copies without the patch) |
| 1280 to 2048 | Clean (zoomed and split without the patch) |
| 2048 to 1024 | Clean |
| 2048 to 1600, 42 s after the last change | Scrambled |
| 1600 to 1024 | Squashed into the top half, and later drawing landed in the wrong places |
| Then to 2048, then to 1024, over a minute each | Still squashed, until the guest restarted |
| From a fresh boot, one change to 1600x900 | Black (seen by eye; no capture was saved) |
| 1280 | No capture was saved, so not known |

So the patch changes the fault and does not end it. Some widths now work, and a width that fails can leave every
later size wrong until a restart. The clean widths are all multiples of 512, which may mean nothing with three
widths. The patch was undone: it would need Test Mode and a self-signed certificate on every guest, and a
resize could still reach a bad width.

An unchanged thumbnail is not a result: the app keeps the last picture when a capture is black, and the timer
slows while the window is in the background.

**Stopping the display device crashes Windows.** Measured twice, once from `pnputil /restart-device` and once
from `pnputil /add-driver /install`, each with the original driver running. Both are bugcheck 0x124 with parameter
0x11 (Arm synchronous external abort), from a 16-bit write faulting at the same physical address, 0x280014000.
The stack in both dumps runs from the driver's teardown through `DestroyFrameBufferObj` to `strh w1, [x8]`,
which is the virtqueue notify. `setupapi.dev.log` ends at `{Restarting Devices}`. That the device is already off
when the notify happens is inferred. A driver can still be changed safely by pointing the service's `ImagePath` at
it and restarting, with no live stop.

**The second display.** Windows also shows an invisible display, measured
(`docs/evidence/windows-second-display-2026-11-11.md`): the Microsoft Basic Display Driver, root-enumerated
(`ROOT\BasicDisplay`), at 1920x1080 to the right of the VirtIO display, over the boot frame buffer
`openvm-framebuffer.efi` makes in reserved RAM. Windows hands a boot display over to a PCI driver whose device
memory holds it, and the virtio-gpu device holds no frame-buffer memory, so the hand-over never happens. Windows
can move to it: a window dragged off the right edge is lost. Settings > Display > "Show only on" the VirtIO
display hides it, and that survives a restart. It is not the cause of the scramble. The agent now does that
itself: before each mode change (the first comes when the guest is ready) its display helper switches off every
active display not on the virtio GPU, provided a virtio display stays on, and saves it as Settings does. If
`viogpudo` has failed, the Basic Display is left alone. Measured on `win-lab`: the Basic Display went inactive
(`EnumDisplayDevices` flags 0x0, no mode), Settings read "Show only on 2" (the VirtIO display), and it stayed
so after a restart from the Start menu. Settings still lists the second monitor, inactive, because Windows lists
every connected monitor. Guests installed before this keep the second display until they get the new agent.

**The stopgap, removed.** Until 2026-11-12 the app held a Windows guest at 1024 pixels wide, with the height
following the window, which kept the picture correct with the released driver (measured: three clean captures at
1024x643, 1024x590 and 1024x640, across a restart and in use) but softer than a Retina display can show. View ▸
Full Size Display lifted it for a guest with the fixed driver. The owner chose the full size always, so a Windows
guest now needs a `viogpudo` with the mode-change fix.

**A restart from inside Windows.** The VM keeps running through it and the framework reports nothing, so the app
never sizes the guest again, and Windows came back at 1024x768 refusing every other size from
`ChangeDisplaySettingsEx` (`docs/evidence/windows-restart-display-2026-11-12.md`). The agent now remembers the last
size the Mac asked for (`C:\openvm\display-mode.txt`) and applies it again once someone is signed in. When
Windows refuses `ChangeDisplaySettingsEx`, the helper lists the size with viogpudo's escape and sets the source
mode with `SetDisplayConfig`, as virtio-win's `viogpuap` does. viogpudo sizes its frame buffer at start from
`PersistentDispMode0Width/Height`, so the agent keeps that at least 5120x2880 and never lowers it. A window resized while Windows restarts is corrected at the next resize.

## Linux, from an ISO

`--boot-mode linux-iso` (the wizard's "Linux, from an ISO") is a plain UEFI machine: firmware, a
blank virtio disk, and the ISO on a USB stick, with the distribution's own installer in the VM window.
There is no per-distribution code. Any ARM64 build that boots by UEFI should work.

* **The size.** The view resizes the display itself (`automaticallyReconfiguresDisplay`), and the guest's kernel
  sees each new size, but Hyprland keeps the size it read at login, which leaves black bars after a resize and in
  full screen. `tools/guest/hyprland/openvm-fit-display.sh`, started at login, switches it
  (`docs/evidence/linux-display-fit-2026-11-12.md`, README "Create a Linux guest").

* **The check.** `linux-iso-check` scans the file for the boot file names, because macOS could not mount
  the hybrid ISO tried. It refuses an ISO with only x86-64 names, and lets one with neither through with a
  note that it may or may not start.
* **No agent.** These guests have no openVM agent, so a boot is done when the firmware has the machine,
  and every channel op answers "this guest has no openVM tools" at once. The controls that need the agent
  are off or hidden. Resizing is the framework's own (`automaticallyReconfiguresDisplay`), which depends
  on the guest's display driver and desktop.
* **Clipboard, by choice.** The clipboard switch (Settings, or Devices ▸ Share Clipboard) is off for these
  guests until someone turns it on, and takes effect at the next start. On, the VM gets the framework's Spice
  agent port (`VZSpiceAgentPortAttachment`), and the guest needs `spice-vdagent`. That program shares the
  clipboard on X11 desktops only; Omarchy's Hyprland and most Wayland desktops are not covered. Unlike
  openVM's agent it has no filter, so passwords are shared too, which is why it is not on by default. Not yet
  seen working on a real guest.
* **Sound.** The VM has Apple's virtio-sound device. It plays silence when the guest writes periods of 5 ms
  or less, and it needs more than two periods buffered (measured: `docs/evidence/linux-iso-sound-2026-11-11.md`).
  PipeWire's default drives it with 2.5 ms periods, so a PipeWire desktop such as Omarchy is silent until the
  guest gets `tools/guest/pipewire/51-openvm-sound.conf` (README, "If the guest makes no sound"). With it,
  PipeWire held 10.7 ms periods and a 43 ms buffer, and the guest was heard. openVM cannot set this from the
  host: the device has no period setting, and these guests have no agent. Sound arrives about 115 to 137 ms
  after the guest plays it (measured with an 85 ms guest buffer); a native Mac app measured 13 ms.
* **Stopping.** There is no agent to ask, so the guest gets the framework's stop request and 120 seconds.
  A guest that ignores the request is then forced off.
* **After the install.** The firmware's variable store is kept, so the installer's boot entry survives. A
  restart stops the VM (the framework has no reboot), so press Start. Devices ▸ Eject Installer ISO, or
  `openvmctl eject`, takes the ISO away; the person's file is left where it is, and deleting the VM does
  not touch it.

**Measured with a real ISO** (`omarchy-4.5.0-aarch64.iso`, a person at the keyboard): the ISO passed the
check and booted; its installer took keyboard and pointer input; the picture filled the window, correct
at the view's size. Asked to stop from the host, that guest did not stop within 120 seconds and was forced
off, so shut these guests down from inside. Alpine's ARM64 and x86_64 virt ISOs were told apart by the
check, and a cut-off file was refused. An installed Omarchy 7.3 started from its disk and was used on
2026-11-11. Not yet seen on a real guest: live resizing, and any distribution other than Omarchy.
