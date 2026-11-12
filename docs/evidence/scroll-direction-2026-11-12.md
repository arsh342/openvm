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
  Mac, up and down and sideways (owner, by hand). Set back to 0 and the mouse restarted with
  `pnputil /restart-device`, with no restart of Windows, scrolling went back to reversed at once.
* **Pinch to zoom** does nothing in either guest: the framework's pointer for these guests has no gestures.
  Control with a two-finger scroll zooms web pages (owner, Windows).

## The agent sets it

The Windows agent now sets `FlipFlopWheel` = 1 on every present mouse when it starts, and restarts a mouse whose
value changed (`SetupDiCallClassInstaller` with `DIF_PROPERTYCHANGE`, as `pnputil /restart-device` does). On
`win-lab`, with the value set back to 0 and the mouse restarted first, installing the new agent gave:

```
HID-compliant mouse [HID\VID_05AC&PID_8106\6&E98C78C&0&0000]: FlipFlopWheel=0     (before)
2026-11-12 15:42:50 scrolling: natural on 1 mice, 1 changed now, 0 failed
HID-compliant mouse [HID\VID_05AC&PID_8106\6&E98C78C&0&0000]: FlipFlopWheel=1     (after)
```

The guest has one mouse, Apple's pointer (`VID_05AC&PID_8106`). A live restart of the mouse did not crash, unlike
a live restart of the display device.

The traces and the research build's changes are kept outside the repository.
