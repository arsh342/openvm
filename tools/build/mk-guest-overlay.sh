#!/bin/sh
# Build the Alpine apkovl overlay that compiles and installs the openvm-tools
# agent. On first boot with an attached blank disk it also installs Alpine to
# that disk; subsequent boots use the disk as root.
#   usage: mk-guest-overlay.sh <out-dir>   → <out-dir>/openvm.apkovl.tar.gz
set -eu

OUT="$1"
STAGE="$OUT/stage"
AGENT_SRC="tools/guest/openvm-tools.c"
rm -rf "$STAGE"
mkdir -p "$STAGE/etc/local.d" "$STAGE/etc/runlevels/default" "$STAGE/opt/openvm"
mkdir -p "$STAGE/etc/xdg/autostart" "$STAGE/usr/local/bin"
# Tell Alpine's initramfs to retain its standard boot services (including
# modloop, which provides the kernel modules absent from the tiny netboot root).
: > "$STAGE/etc/.default_boot_services"
cp "$AGENT_SRC" "$STAGE/opt/openvm/openvm-tools.c"
cp -R tools/guest/linux "$STAGE/opt/openvm/linux"
cp tools/guest/ovmc_codec.h "$STAGE/opt/openvm/ovmc_codec.h"
cp tools/guest/openvm-zboot.c "$STAGE/opt/openvm/openvm-zboot.c"
cp tools/guest/openvm-clipboard-backend.sh "$STAGE/opt/openvm/openvm-clipboard-backend.sh"
cp tools/guest/openvm-clipboard-session.sh "$STAGE/usr/local/bin/openvm-clipboard-session"
cp tools/guest/openvm-print-backend "$STAGE/opt/openvm/openvm-print-backend"
cp tools/guest/openvm-display-backend.sh "$STAGE/opt/openvm/openvm-display-backend.sh"
cp tools/guest/openvm-desktop-server "$STAGE/opt/openvm/openvm-desktop-server"
cp tools/guest/openvm-desktop-session "$STAGE/opt/openvm/openvm-desktop-session"
cp tools/guest/openvm-asound.conf "$STAGE/opt/openvm/openvm-asound.conf"
cp tools/guest/openvm-xorg.conf "$STAGE/opt/openvm/openvm-xorg.conf"
cp tools/guest/openvm-pdf.ppd "$STAGE/opt/openvm/openvm-pdf.ppd"
chmod +x "$STAGE/opt/openvm/openvm-clipboard-backend.sh" "$STAGE/usr/local/bin/openvm-clipboard-session"
cat > "$STAGE/etc/xdg/autostart/openvm-clipboard.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=openVM Clipboard Session
Exec=/usr/local/bin/openvm-clipboard-session
NoDisplay=true
DESKTOP

# The job detaches so OpenRC can finish bringing up the initramfs guest.
cat > "$STAGE/etc/local.d/openvm-tools.start" <<'EOF'
#!/bin/sh
set -eu
(
    exec >>/dev/console 2>&1
    echo "openvm-tools: preparing virtio-vsock channel on port 52"
    echo "openvm-tools: kernel command line: $(cat /proc/cmdline)"
    # The socket family can bind/listen without a transport, so loading only
    # `vsock` is not enough. Linux names the virtio transport module
    # vmw_vsock_virtio_transport (not virtio_vsock).
    modprobe vsock || true
    modprobe vmw_vsock_virtio_transport || true
    if [ ! -d /sys/bus/virtio/drivers/vmw_vsock_virtio_transport ]; then
        echo "openvm-tools: virtio-vsock transport driver is unavailable"
        exit 1
    fi
    bound=0
    for device in /sys/bus/virtio/drivers/vmw_vsock_virtio_transport/*; do
        [ -e "$device" ] || continue
        case "${device##*/}" in virtio*) ;; *) continue ;; esac
        echo "openvm-tools: virtio-vsock transport bound to ${device##*/}"
        bound=1
    done
    if [ "$bound" -ne 1 ]; then
        echo "openvm-tools: virtio-vsock transport has no bound device"
        exit 1
    fi
    [ -x /usr/bin/cc ] && [ -f /usr/include/linux/vm_sockets.h ] || \
        apk add --no-cache gcc musl-dev linux-headers
    mkdir -p /opt/openvm
    cd /opt/openvm
    case " $(cat /proc/cmdline) " in
        *" openvm.install=1 "*) ;;
        *)
            # A persistent disk already contains the compiled agent. Use it
            # directly; the source/build toolchain only exists on netboot.
            if [ -x /opt/openvm/openvm-tools ]; then
                exec /opt/openvm/openvm-tools
            fi
            ;;
    esac
    cc -O2 -o openvm-tools openvm-tools.c || {
        echo "openvm-tools: compile failed"; exit 1; }

    case " $(cat /proc/cmdline) " in
        *" openvm.install=1 "*)
            echo "openvm-tools: installing Alpine onto /dev/vda"
            apk add --no-cache alpine-conf netcat-openbsd zlib-dev || exit 1
            BOOTLOADER=none ERASE_DISKS=/dev/vda setup-disk -m sys -s 0 /dev/vda || {
                echo "openvm-tools: setup-disk failed"; exit 1; }

            # setup-disk unmounts its target on success. Find the root
            # partition by mounting its partitions and checking the generated
            # fstab, rather than assuming a partition number.
            mkdir -p /mnt
            root_device=
            for part in /dev/vda[0-9]*; do
                [ -b "$part" ] || continue
                mount "$part" /mnt 2>/dev/null || continue
                if [ -f /mnt/etc/fstab ] && \
                    awk '$2 == "/" { found=1 } END { exit !found }' /mnt/etc/fstab; then
                    root_device=$part
                    break
                fi
                umount /mnt
            done
            [ -n "$root_device" ] || {
                echo "openvm-tools: could not find installed root partition"; exit 1; }

            # setup-disk may create a separate /boot. Match its fstab UUID and
            # mount that filesystem before reading the kernel or writing initramfs.
            boot_spec=$(awk '$2 == "/boot" { print $1; exit }' /mnt/etc/fstab)
            if [ -n "$boot_spec" ]; then
                boot_uuid=${boot_spec#UUID=}
                boot_uuid=${boot_uuid#PARTUUID=}
                boot_device=
                for part in /dev/vda[0-9]*; do
                    [ -b "$part" ] || continue
                    [ "$part" = "$root_device" ] && continue
                    part_id=$(blkid "$part" 2>/dev/null | sed -n 's/.*UUID="\([^"]*\)".*/\1/p')
                    [ "$part_id" = "$boot_uuid" ] && { boot_device=$part; break; }
                done
                [ -n "$boot_device" ] || {
                    echo "openvm-tools: separate /boot partition from fstab was not found"; exit 1; }
                mkdir -p /mnt/boot
                mount "$boot_device" /mnt/boot || exit 1
            fi

            # Generate from the installed release and its complete modules,
            # rather than trying to patch the smaller netboot initramfs.
            apk add --no-cache mkinitfs || {
                echo "openvm-tools: could not install mkinitfs in the live environment"; exit 1; }
            apk --root /mnt add mkinitfs || {
                echo "openvm-tools: could not install mkinitfs into target root"; exit 1; }
            set -- /mnt/lib/modules/*
            [ -d "$1" ] && [ "$#" -eq 1 ] || {
                echo "openvm-tools: expected one installed kernel module tree"; exit 1; }
            kernel_release=${1##*/}
            [ -f /mnt/boot/vmlinuz-virt ] || {
                echo "openvm-tools: installed virt kernel not found in /boot"; exit 1; }
            mkinitfs -c /mnt/etc/mkinitfs/mkinitfs.conf -b /mnt \
                -F "base virtio ext4" -o /mnt/boot/initramfs-openvm "$kernel_release" || {
                echo "openvm-tools: mkinitfs failed for $kernel_release"; exit 1; }

            # VZLinuxBootLoader needs a raw ARM64 Image. Extract it from the
            # installed kernel's zboot container and check the ARMd magic.
            cc -O2 -o /tmp/openvm-zboot /opt/openvm/openvm-zboot.c -lz || {
                echo "openvm-tools: could not build the kernel unpacker"; exit 1; }
            /tmp/openvm-zboot /mnt/boot/vmlinuz-virt /mnt/boot/openvm-vmlinuz || {
                echo "openvm-tools: could not extract installed ARM64 kernel"; exit 1; }
            [ -s /mnt/boot/openvm-vmlinuz ] || {
                echo "openvm-tools: could not extract installed ARM64 kernel"; exit 1; }

            vm_uuid=$(sed -n 's/.*openvm.uuid=\([^ ]*\).*/\1/p' /proc/cmdline)
            upload_port=$(sed -n 's/.*openvm.artifact-port=\([0-9]*\).*/\1/p' /proc/cmdline)
            upload_token=$(sed -n 's/.*openvm.artifact-token=\([0-9a-f]*\).*/\1/p' /proc/cmdline)
            [ -n "$vm_uuid" ] && [ -n "$upload_port" ] && [ -n "$upload_token" ] || {
                echo "openvm-tools: artifact upload settings missing from kernel command line"; exit 1; }
            upload_artifact() {
                kind=$1
                file=$2
                size=$(wc -c < "$file" | tr -d ' ')
                response=$(mktemp)
                { printf 'POST /install/%s/%s HTTP/1.1\r\nHost: 192.168.64.1\r\nX-OpenVM-Token: %s\r\nContent-Length: %s\r\nConnection: close\r\n\r\n' \
                    "$vm_uuid" "$kind" "$upload_token" "$size"; cat "$file"; } |
                    nc -w 120 192.168.64.1 "$upload_port" > "$response" || return 1
                grep -q '201 Created' "$response"
                result=$?
                rm -f "$response"
                return "$result"
            }
            upload_artifact kernel /mnt/boot/openvm-vmlinuz &&
                upload_artifact initramfs /mnt/boot/initramfs-openvm || {
                echo "openvm-tools: failed to upload matching kernel/initramfs to host"; exit 1; }

            mkdir -p /mnt/opt/openvm /mnt/usr/local/bin /mnt/etc/xdg/autostart \
                /mnt/etc/local.d /mnt/etc/init.d /mnt/etc/runlevels/default
            cp /opt/openvm/openvm-tools.c /mnt/opt/openvm/openvm-tools.c
            cp /opt/openvm/openvm-clipboard-backend.sh /mnt/opt/openvm/openvm-clipboard-backend.sh
            cp /usr/local/bin/openvm-clipboard-session /mnt/usr/local/bin/openvm-clipboard-session
            cp ./openvm-tools /mnt/opt/openvm/openvm-tools
            cp /etc/xdg/autostart/openvm-clipboard.desktop /mnt/etc/xdg/autostart/openvm-clipboard.desktop
            chmod +x /mnt/opt/openvm/openvm-clipboard-backend.sh \
                /mnt/usr/local/bin/openvm-clipboard-session
            # setup-disk copies the live overlay too. Remove that installer
            # hook so only the dedicated service owns the persistent listener.
            rm -f /mnt/etc/local.d/openvm-tools.start
            cat > /mnt/etc/init.d/openvm-tools <<'SERVICE'
#!/sbin/openrc-run
description="openVM guest channel agent"
command="/opt/openvm/openvm-tools"
command_background="yes"
pidfile="/run/openvm-tools.pid"
output_log="/dev/console"
error_log="/dev/console"

depend() {
    need localmount
    after bootmisc modules
}

start_pre() {
    exec >>/dev/console 2>&1
    echo "openvm-tools: starting persistent guest agent"
    modprobe vsock || return 1
    modprobe vmw_vsock_virtio_transport || return 1
    [ -x "$command" ]
}
SERVICE
            chmod +x /mnt/etc/init.d/openvm-tools
            ln -sf /etc/init.d/openvm-tools /mnt/etc/runlevels/default/openvm-tools
            # The clipboard bridge needs a real X11/Wayland session to talk to.
            # Persistent installs get a headless X server plus xclip so the
            # desktop bridge is exercised on real boots, not just unit tests.
            desktop_repos=$(printf '%s\n' \
                "https://dl-cdn.alpinelinux.org/alpine/v$(cut -d. -f1-2 /mnt/etc/alpine-release)/main" \
                "https://dl-cdn.alpinelinux.org/alpine/v$(cut -d. -f1-2 /mnt/etc/alpine-release)/community")
            echo "$desktop_repos" > /mnt/etc/apk/repositories
            # XFCE piece by piece: the xfce4 meta-package also brings the power
            # manager, and the host owns sleep and blanking.
            apk --root /mnt add xvfb xorg-server xf86-input-evdev xrandr xinput xset scrot xclip tzdata \
                dbus-x11 xfce4-session xfwm4 xfce4-panel xfdesktop xfce4-settings xfce4-terminal \
                thunar adwaita-icon-theme font-dejavu alsa-utils || {
                echo "openvm-tools: desktop packages failed to install"; exit 1; }
            chroot /mnt adduser -D -g "openVM" openvm
            chroot /mnt adduser openvm video
            chroot /mnt adduser openvm input
            chroot /mnt adduser openvm audio
            # Host printers appear as CUPS queues that end in a PDF.
            # font-dejavu: texttopdf has nothing to set plain text in without it.
            apk --root /mnt add cups cups-filters font-dejavu || {
                echo "openvm-tools: printing packages failed to install"; exit 1; }
            cp /opt/openvm/openvm-pdf.ppd /mnt/opt/openvm/openvm-pdf.ppd
            cp /opt/openvm/openvm-xorg.conf /mnt/opt/openvm/openvm-xorg.conf
            install -m 0755 /opt/openvm/openvm-display-backend.sh /opt/openvm/openvm-desktop-server \
                /opt/openvm/openvm-desktop-session /mnt/opt/openvm/
            cp /opt/openvm/openvm-asound.conf /mnt/etc/asound.conf
            install -m 0755 /opt/openvm/openvm-print-backend /mnt/usr/lib/cups/backend/openvm
            mkdir -p /mnt/var/spool/openvm-print
            chroot /mnt chown lp:lp /var/spool/openvm-print
            chmod 0770 /mnt/var/spool/openvm-print
            # CUPS admin operations require SystemGroup (lpadmin), and root is
            # not in it by default: the agent's lpadmin gets "Forbidden".
            chroot /mnt addgroup root lpadmin
            ln -sf /etc/init.d/cupsd /mnt/etc/runlevels/default/cupsd
            cat > /mnt/etc/init.d/openvm-clipdesk <<'CLIPDESK'
#!/sbin/openrc-run
description="openVM guest desktop (the X server clipboard and display use)"
command="/opt/openvm/openvm-desktop-server"
command_background="yes"
pidfile="/run/openvm-clipdesk.pid"
output_log="/dev/console"
error_log="/dev/console"

depend() {
    need localmount
}

CLIPDESK
            chmod +x /mnt/etc/init.d/openvm-clipdesk
            ln -sf /etc/init.d/openvm-clipdesk /mnt/etc/runlevels/default/openvm-clipdesk
            # Its own service: a process left in the background by start_post
            # does not survive the service start.
            cat > /mnt/etc/init.d/openvm-session <<'SESSION'
#!/sbin/openrc-run
description="openVM guest desktop session (XFCE, unprivileged user)"
command="/opt/openvm/openvm-desktop-session"
command_background="yes"
pidfile="/run/openvm-session.pid"
output_log="/dev/console"
error_log="/dev/console"

depend() {
    need openvm-clipdesk
    use dbus
}
SESSION
            chmod +x /mnt/etc/init.d/openvm-session
            ln -sf /etc/init.d/openvm-session /mnt/etc/runlevels/default/openvm-session
            # The netboot image configures eth0 from its initramfs, so a
            # persistent install comes up with no network at all and cannot
            # reach the host gateway (192.168.64.1) where the shared-folder
            # server listens. Bring eth0 up with DHCP from the local service.
            # This one file plays both roles: the local service runs it with
            # no arguments to start the client, udhcpc calls it back on a
            # lease event.
            cat > /mnt/etc/local.d/net.start <<'NETSTART'
#!/bin/sh
# openVM: DHCP for eth0. The installed root has no networking service, and
# the netboot initramfs that configured eth0 is long gone. busybox's udhcpc
# exports the lease as $ip/$mask (prefix length) plus $router and $dns.
if [ $# -eq 0 ]; then
    ip link set eth0 up 2>/dev/null
    exec udhcpc -i eth0 -b -q -t 20 -T 3 -s "$0"
fi

case "$1" in
    bound|renew)
        ip -4 addr show dev $interface | grep -q "$ip/" ||
            ip -4 addr add "$ip/$mask" dev $interface
        ip -4 link set dev $interface up
        ip -4 route show | grep -q '^default' ||
            ip -4 route add default via "${router%% *}" dev $interface
        [ -n "${dns:-}" ] && echo "nameserver $dns" >/etc/resolv.conf
        echo "openvm: eth0 $ip/$mask via $router"
        ;;
esac
exit 0
NETSTART
            chmod +x /mnt/etc/local.d/net.start
            # The first ping runs from the live root. Commit the installed
            # service and binary before the host can stop this VM.
            sync
            if [ -n "$boot_spec" ]; then
                umount /mnt/boot
            fi
            umount /mnt
            echo "OPENVM_DISK_READY=$root_device"
            exec ./openvm-tools
            ;;
        *)
            exec ./openvm-tools
            ;;
    esac
) &
exit 0
EOF
chmod +x "$STAGE/etc/local.d/openvm-tools.start"

# enable the openrc "local" service so the rc script runs at boot
ln -fs /etc/init.d/local "$STAGE/etc/runlevels/default/local"

tar -C "$STAGE" -czf "$OUT/openvm.apkovl.tar.gz" etc opt usr
echo "mk-guest-overlay: wrote $OUT/openvm.apkovl.tar.gz"
