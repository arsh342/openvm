# A Linux guest's size in the window and in full screen, 2026-11-12

Guest: `linux-vm`, Omarchy (Hyprland with its Lua config), installed from its ISO, no openVM tools. The app sets
`automaticallyReconfiguresDisplay` on the VM view for guests without an agent. Mac: built-in 2560x1664 Retina
display with a notch, so full screen leaves 2560x1600 below it.

## The fault

The guest filled the window it started in (2496x1440 at Hyprland's own 1.33 scale), but a resized window showed
black bars at the sides and full screen showed bars at the top and bottom. `hyprctl monitors` still gave
2496x1440 in full screen, with 2496x1440 first in its `availableModes`.

## Where it stops

* **The Mac side works.** After a resize, the kernel listed the window's new size first:
  `/sys/class/drm/card*-Virtual-1/modes` began `2936x1580`, while Hyprland still offered 2496x1440 first.
* **Hyprland does not switch.** `hl.monitor` with `mode = "preferred"` changed the scale but kept 2496x1440:
  Hyprland's "preferred" is from the mode list it read at login. With the kernel's first mode named
  explicitly (`mode = "2936x1580"`), the bars went away, and came back at the next resize.

## The fix

`tools/guest/hyprland/openvm-fit-display.sh` waits for the kernel's DRM change events (`udevadm monitor`) and
gives Hyprland the mode the kernel lists first, at scale 2. Started by hand, and then from
`~/.config/hypr/autostart.lua` after a restart of the VM, the desktop filled the window after every resize and in
full screen (owner, by eye). A Linux guest that restarts itself stops the VM, so the in-place restart fault of
Windows guests does not arise. Other desktops were not checked.
