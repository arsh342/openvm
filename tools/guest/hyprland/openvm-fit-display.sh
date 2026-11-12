#!/bin/sh
# openvm-fit-display — makes Hyprland follow the openVM window's size.
#
# When the window is resized or goes full screen, the Mac gives the VM's display a
# new preferred size and the kernel lists it first in the connector's modes. Hyprland
# does not switch to it by itself, and its "preferred" still names the size it read at
# login (measured with Omarchy, 2026-11-12). So this waits for the kernel's display
# change events and gives Hyprland the size the kernel lists first.
#
# Start it with the session, for example in Omarchy's ~/.config/hypr/autostart.lua.
# OPENVM_SCALE sets the scale (default 2, a Retina Mac; use 1 on a non-Retina display).
set -u

scale=${OPENVM_SCALE:-2}
last=""

fit() {
    for modes in /sys/class/drm/card*-Virtual-*/modes; do
        [ -r "$modes" ] || continue
        name=${modes%/modes}
        name=${name##*/}
        name=${name#card*-}
        mode=$(head -n 1 "$modes")
        [ -n "$mode" ] || continue
        [ "$name:$mode" != "$last" ] || continue
        hyprctl eval "hl.monitor({ output = \"$name\", mode = \"$mode\", position = \"auto\", scale = $scale })" >/dev/null
        last="$name:$mode"
    done
}

fit
udevadm monitor --udev --subsystem-match=drm | while read -r line; do
    case $line in
    *change*) fit ;;
    esac
done
