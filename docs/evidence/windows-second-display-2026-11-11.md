# The second display in Windows guests, 2026-11-11

Guest `win-lab`, a fresh Windows 11 ARM64 (26100) install from openVM's media, virtio-win 0.1.302.
Collected in the guest by a read-only script: `Get-PnpDevice`, `Win32_PnPAllocatedResource`,
`Win32_VideoController`, the `root\wmi` monitor classes, `EnumDisplayDevices`/`EnumDisplaySettings`,
and `dxdiag /t`.

| | `\\.\DISPLAY1` | `\\.\DISPLAY2` |
| --- | --- | --- |
| Driver | Microsoft Basic Display Driver (`basicdisplay.sys`) | Red Hat VirtIO GPU DOD controller (`viogpudo.sys`) |
| Device | `ROOT\BasicDisplay` (root-enumerated, no hardware) | `PCI\VEN_1AF4&DEV_1050`, PCI bus 0 device 9 |
| Mode, position | 1920x1080 at (1024,0) | 1024x768 at (0,0) |
| Monitor | Generic Non-PnP Monitor, output type Other | Generic PnP Monitor (`RHT1234`), output HD15 |
| Memory the device holds | none (not a PnP device) | 0x280010000-0x28001FFFF and 0x50005000-0x5000503F only |

`Win32_VideoController` lists only the VirtIO controller: it does not report the root-enumerated Basic Display
Driver, which is why an earlier check saw one adapter while Settings showed two displays.

## Reading

Windows starts the Basic Display Driver on the frame buffer the firmware described at boot. When a PCI display
driver loads, Windows hands that display over to it if the frame buffer lies in that device's memory. openVM's
`tools/uefi/openvm-framebuffer.c` puts the frame buffer in reserved RAM, because Apple's virtio-gpu device has
no frame-buffer memory, and sets the largest mode within its 1920x1200 cap, 1920x1080 here. That matches the
Basic Display Driver's mode. The virtio-gpu device holds no range that contains it, so the hand-over cannot
happen and the Basic Display Driver keeps a second, invisible display. That the hand-over test is a
memory-range match is the documented model, not something measured here.

This is not the cause of the scramble (`docs/evidence/viogpudo-mode-change-trace-2026-11-11.md`).

## Options

* Stop advertising the boot frame buffer: no, Windows Boot Manager needs it to draw.
* Disable `BasicDisplay`: no, it is Windows' fallback if `viogpudo` fails.
* Have the agent keep only the VirtIO display active at sign-in (what Settings > Display > "Show only on"
  does), and only while the VirtIO display is up, so the fallback stays. Not built yet.
