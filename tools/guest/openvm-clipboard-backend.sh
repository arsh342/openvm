#!/bin/sh
# Called by the root-owned channel agent. Read only named environment values;
# never source the user-owned session file as shell code.
set -eu

mode=${1:-}
case "$mode" in
    read|write) ;;
    *) echo "openvm clipboard: invalid operation" >&2; exit 2 ;;
esac

session_file=
for candidate in /run/user/*/openvm-clipboard.env; do
    [ -f "$candidate" ] || continue
    session_file=$candidate
    break
done
[ -n "$session_file" ] || {
    echo "no logged-in desktop clipboard session" >&2
    exit 1
}

WAYLAND_DISPLAY=
DISPLAY=
XDG_RUNTIME_DIR=
XAUTHORITY=
while IFS= read -r entry; do
    case "$entry" in
        WAYLAND_DISPLAY=*) WAYLAND_DISPLAY=${entry#*=} ;;
        DISPLAY=*) DISPLAY=${entry#*=} ;;
        XDG_RUNTIME_DIR=*) XDG_RUNTIME_DIR=${entry#*=} ;;
        XAUTHORITY=*) XAUTHORITY=${entry#*=} ;;
    esac
done < "$session_file"
export WAYLAND_DISPLAY DISPLAY XDG_RUNTIME_DIR XAUTHORITY

if [ -n "$WAYLAND_DISPLAY" ] && command -v wl-copy >/dev/null 2>&1 && \
   command -v wl-paste >/dev/null 2>&1; then
    if [ "$mode" = read ]; then
        exec wl-paste --no-newline --type text/plain;charset=utf-8
    else
        exec wl-copy --type text/plain;charset=utf-8
    fi
fi

if [ -n "$DISPLAY" ] && command -v xclip >/dev/null 2>&1; then
    if [ "$mode" = read ]; then
        exec xclip -selection clipboard -o
    else
        exec xclip -selection clipboard -i
    fi
fi

echo "no supported guest clipboard utility/session (install wl-clipboard or xclip)" >&2
exit 1
