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
  only. Between resizes the view scales the last frame, so a window dragged larger shows no
  failure.
* A scale Windows refuses ("Windows allows at most N% at this size", and the agent's other
  scale refusals) steps down to the highest one it allows. Any other failure, such as an
  unreachable guest, is tried once.

To check by hand: drag the window to a new size, wait a second, and run
`openvmctl display capture <vm>` then `file pull`; the capture's pixel size should be the
window's size in points times 2. Also try full screen, and moving the window to a
non-Retina display if one is attached. Record how long the guest takes to settle after you
stop dragging.
