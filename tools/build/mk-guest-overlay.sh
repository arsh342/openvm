#!/bin/sh
# Build the Alpine apkovl overlay the helper VM boots with. The helper VM is a short-lived Alpine
# netboot guest that builds Windows install media when the Mac has no wimlib; the overlay carries
# the script that runs its one job. openVM does not make Alpine guests for people to use.
#   usage: mk-guest-overlay.sh <out-dir>   → <out-dir>/openvm.apkovl.tar.gz
set -eu

OUT="$1"
STAGE="$OUT/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/etc/local.d" "$STAGE/etc/runlevels/default"
# Tell Alpine's initramfs to retain its standard boot services (including
# modloop, which provides the kernel modules absent from the tiny netboot root).
: > "$STAGE/etc/.default_boot_services"

# A boot with openvm.job=wim runs one script from a shared folder on the host, then powers off.
# The host reads the result from a status file in that folder.
cat > "$STAGE/etc/local.d/openvm-job.start" <<'JOBEOF'
#!/bin/sh
cmdline=$(cat "${OPENVM_CMDLINE:-/proc/cmdline}")
case " $cmdline " in *" openvm.job=wim "*) ;; *) exit 0 ;; esac

mount_dir=${OPENVM_JOB_MOUNT:-/mnt/job}
log=${OPENVM_JOB_LOG:-/dev/console}

run_job() {
    exec >>"$log" 2>&1
    echo "openvm-job: starting"
    # The host reads the status file; with the folder unmounted there is nowhere to write it,
    # and the host sees the VM stop with no status.
    report() {
        echo "openvm-job: $1"
        printf 'error: %s\n' "$1" > "$mount_dir/job/status" 2>/dev/null || true
        sync
        poweroff -f
        exit 1
    }
    modprobe virtiofs 2>/dev/null || true
    mkdir -p "$mount_dir"
    mount -t virtiofs job "$mount_dir" || report "could not mount the job folder"
    # wimlib is in Alpine's community repository, not main. It is installed in this throwaway
    # guest each time; nothing GPL is shipped with openVM.
    base="https://dl-cdn.alpinelinux.org/alpine/v$(cut -d. -f1,2 "${OPENVM_ALPINE_RELEASE:-/etc/alpine-release}")"
    apk add --no-cache --repository "$base/main" --repository "$base/community" wimlib \
        || report "could not install wimlib; the Mac needs to be online"
    sh "$mount_dir/job/job.sh" "$mount_dir/iso" "$mount_dir/job" || report "the job failed"
    echo ok > "$mount_dir/job/status"
    sync
    poweroff -f
}

# Detached, so OpenRC can finish bringing up the guest; tests run it in the foreground.
if [ -n "${OPENVM_JOB_FOREGROUND:-}" ]; then
    run_job
else
    run_job &
fi
JOBEOF
chmod +x "$STAGE/etc/local.d/openvm-job.start"

# enable the openrc "local" service so the rc script runs at boot
ln -fs /etc/init.d/local "$STAGE/etc/runlevels/default/local"

tar -C "$STAGE" -czf "$OUT/openvm.apkovl.tar.gz" etc
echo "mk-guest-overlay: wrote $OUT/openvm.apkovl.tar.gz"
