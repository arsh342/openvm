#!/bin/sh
# XDG autostart hook. Publish the desktop session environment for the root-owned
# OVMC agent without keeping this process or a shell sourced by root alive.
set -eu

[ -n "${XDG_RUNTIME_DIR:-}" ] || exit 0
[ -d "$XDG_RUNTIME_DIR" ] || exit 0
umask 077
tmp="$XDG_RUNTIME_DIR/.openvm-clipboard-env.$$"
trap 'rm -f "$tmp"' EXIT HUP INT TERM
{
    printf 'WAYLAND_DISPLAY=%s\n' "${WAYLAND_DISPLAY:-}"
    printf 'DISPLAY=%s\n' "${DISPLAY:-}"
    printf 'XDG_RUNTIME_DIR=%s\n' "$XDG_RUNTIME_DIR"
    printf 'XAUTHORITY=%s\n' "${XAUTHORITY:-}"
} > "$tmp"
mv -f "$tmp" "$XDG_RUNTIME_DIR/openvm-clipboard.env"
trap - EXIT HUP INT TERM
