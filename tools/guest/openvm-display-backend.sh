#!/bin/sh
# Called by the root-owned channel agent. `set W H S` adopts the mode the host just
# gave the virtio-gpu display and, unless S is 0, the scale; it prints what the guest
# holds as WxH@S. `capture` saves the screen into the file service's staging
# directory and prints its name.
set -eu

export DISPLAY=:99
stage=/tmp/openvm-share

output() {
    xrandr --query | awk '/ connected/{print $1; exit}'
}

# XFCE's settings live on its session bus, which belongs to the desktop user.
xfconf() {
    uid=$(id -u openvm)
    bus=$(cat "/run/user/$uid/openvm-bus")
    su -s /bin/sh openvm -c "DISPLAY=:99 DBUS_SESSION_BUS_ADDRESS='$bus' xfconf-query $*"
}

set_scale() {
    xfconf -c xsettings -p /Gdk/WindowScalingFactor -n -t int -s "$1" >/dev/null
    # The window manager draws its own frames, from a theme made for each size.
    case "$1" in
        1) theme=Default ;;
        2) theme=Default-xhdpi ;;
        3) theme=Default-xxhdpi ;;
    esac
    [ -d "/usr/share/themes/$theme" ] && xfconf -c xfwm4 -p /general/theme -n -t string -s "$theme" >/dev/null
    xfconf -c xsettings -p /Gdk/WindowScalingFactor
}

case "${1:-}" in
    set)
        want="$2x$3"
        out=$(output)
        [ -n "$out" ] || { echo "no connected display output"; exit 1; }
        # The new mode arrives as a hotplug event just after the host's change.
        i=0
        while :; do
            xrandr --output "$out" --auto >/dev/null 2>&1 || true
            now=$(xrandr --query | sed -n 's/.*current \([0-9]*\) x \([0-9]*\).*/\1x\2/p' | head -1)
            [ "$now" = "$want" ] && break
            i=$((i + 1))
            [ "$i" -lt 20 ] || { echo "X holds $now, not $want"; exit 1; }
            sleep 0.25
        done
        held=0
        [ "${4:-0}" = 0 ] || held=$(set_scale "$4")
        echo "$now@$held"
        ;;
    capture)
        mkdir -p "$stage"
        rm -f "$stage/capture.png"
        scrot "$stage/capture.png"
        echo capture.png
        ;;
    *)
        echo "usage: openvm-display-backend set W H S | capture" >&2
        exit 2
        ;;
esac
