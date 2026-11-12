# Scroll direction in a guest, 2026-11-12

Guests: `linux-vm` (Omarchy, Hyprland with its Lua config, installed from its ISO) and `win-lab` (Windows 11
ARM64), on macOS 27.2 with natural scrolling on. Both guests scrolled opposite to the Mac's direction, on a
trackpad.

## The device

The pointer is Apple's `VZUSBScreenCoordinatePointingDevice`. The Linux guest lists it as
"Apple Inc. Virtual USB Digitizer"; `libinput list-devices` gives it the capability `scroll-nat`, so the
guest can reverse it.

## The app cannot reverse it

View ▸ Reverse Scrolling negated the scroll fields of each event (`scrollingDeltaY`, the CGEvent axis,
point and fixed-point fields) in a local event monitor. A research build traced each event, with its signs, to
`~/.openvm/scroll-trace.log`, and `sudo libinput debug-events` in the guest showed what arrived there.

1. **A flipped copy of the event, from a monitor on the VM window, and then from one monitor for the whole app
   installed before any VM window existed.** The VM view's `scrollWheel(with:)` received the flipped event
   (240 flipped events in one run), and the guest's scroll direction still followed the original event's sign.
2. **A new scroll event made with `CGEvent(scrollWheelEvent2Source:)`, reversed, with the location, flags,
   phases and window fields copied.** 927 were made. They did not reach the VM view. An event an app makes is
   not tied to a window, so AppKit did not deliver it, and the guest got no two-finger scrolling at all.

So `VZVirtualMachineView` does not take the scroll amount from the event it is handed; it reads data in the
original event that an app cannot change. The one way left is to post a generated event through the window
server, which needs Accessibility permission for the whole app. That was not tried.

Others found the same. UTM's "Invert scrolling" only changes its QEMU guests; with Apple's framework users
report it has no effect, and those who fixed the direction did it in the guest (UTM discussion 3764: "Setting
of UTM not work … Setting in Ubuntu works perfect").

## The guest can

* **Linux (Omarchy).** `hyprctl eval 'hl.config({ input = { natural_scroll = true } })'` (Hyprland's Lua config
  refuses `hyprctl keyword`). Effect at once: scrolling matched the Mac (owner, by hand).
* **Windows.** `FlipFlopWheel` = 1 (DWORD) under each mouse-class device's
  `HKLM\SYSTEM\CurrentControlSet\Enum\<instance>\Device Parameters`, then a restart. Scrolling matched the
  Mac (owner, by hand). Horizontal scrolling was not checked.

The traces and the research build's changes are kept outside the repository.
