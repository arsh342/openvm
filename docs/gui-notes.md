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

## To check by hand (needs a person at the keyboard)

The terminal this was built from has no Accessibility or Screen Recording access, so none of
these could be driven or photographed from there. Check on one Linux and one Windows guest,
and write the result next to each line.

* [ ] Typing reaches the guest, including a non-US layout and the Option-key characters.
* [ ] The pointer lands where it is clicked, on a Retina display at scale 2.
* [ ] Cmd+C, Cmd+V, Cmd+W, Cmd+Q and Cmd+Tab: what each does windowed and in full screen.
      Cmd+Q must not quit the app silently while a guest has focus.
* [ ] A menu key equivalent does not swallow a guest shortcut.
* [ ] The boot screen shows through a Windows install.
* [ ] A 12-minute idle stays responsive (past Windows' Modern Standby timer of about 5.5
      minutes).
* [ ] The window title follows the state (Starting, Paused, Stopped), and the cover with a
      Start button shows for a stopped VM.
