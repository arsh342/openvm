/* Shared folder requests (14/15): mounting and unmounting a share. */

static void handle_shared(int fd, const uint8_t *body, const struct ovmc_pair *pairs, size_t count,
                          uint64_t cid) {
    char op[16], name[48], path[256], probe[256];
    probe[0] = '\0';
    if (!text_field(body, pairs, count, "op", op, sizeof op)) {
        shared_response(fd, cid, "shared request has no usable op", NULL);
        return;
    }
    int mounting = strcmp(op, "mount") == 0;
    if (!mounting && strcmp(op, "unmount") != 0) {
        shared_response(fd, cid, "unknown shared op", NULL);
        return;
    }
    if (!text_field(body, pairs, count, "path", path, sizeof path) || !valid_guest_path(path)) {
        shared_response(fd, cid, "shared request has no usable path", NULL);
        return;
    }
    if (mounting &&
        (!text_field(body, pairs, count, "name", name, sizeof name) || !valid_share_name(name))) {
        shared_response(fd, cid, "shared request has no usable share name", NULL);
        return;
    }
    if (find_pair(body, pairs, count, "probe") &&
        (!text_field(body, pairs, count, "probe", probe, sizeof probe) ||
         !valid_probe_name(probe))) {
        shared_response(fd, cid, "shared request has no usable probe name", NULL);
        return;
    }

    /* Every interpolated value was validated above: name is [a-z0-9], path is
     * an absolute path of [A-Za-z0-9._-] components, so the quoting holds. */
    char cmd[1536];
    if (mounting) {
        snprintf(cmd, sizeof cmd,
                 "modprobe virtiofs 2>/dev/null; "
                 /* The host may have replaced the device's share set since the
                  * tag was mounted (a share removed and re-added keeps its name).
                  * Cached dentries/inodes for the old entry then hide the new
                  * contents; dropping them forces fresh lookups over virtio-fs. */
                 "sync; echo 2 > /proc/sys/vm/drop_caches 2>/dev/null; "
                 "mkdir -p " OPENVM_FS_ROOT " && "
                 "{ grep -q ' " OPENVM_FS_ROOT " ' /proc/mounts || "
                 "mount -t virtiofs " OPENVM_FS_TAG " " OPENVM_FS_ROOT "; } 2>&1 && "
                 "{ [ -d '" OPENVM_FS_ROOT "/%s' ] || { umount " OPENVM_FS_ROOT " 2>/dev/null; "
                 "mount -t virtiofs " OPENVM_FS_TAG " " OPENVM_FS_ROOT "; }; } 2>&1 && "
                 "[ -d '" OPENVM_FS_ROOT
                 "/%s' ] || { echo 'share %s is not in the virtio-fs device'; false; } && "
                 "{ umount '%s' 2>/dev/null; mkdir -p '%s' && mount --bind '" OPENVM_FS_ROOT
                 "/%s' '%s'; } 2>&1",
                 name, name, name, path, path, name, path);
    } else {
        snprintf(cmd, sizeof cmd, "umount '%s' 2>&1", path);
    }
    FILE *pipe = popen(cmd, "r");
    if (!pipe) {
        shared_response(fd, cid, "could not run the mount command", NULL);
        return;
    }
    char output[512];
    size_t n = fread(output, 1, sizeof output - 1, pipe);
    output[n] = '\0';
    trim_eol(output);
    int status = pclose(pipe);
    if (status != 0) {
        char reason[768];
        snprintf(reason, sizeof reason, "%s failed: %s [exit %d]", mounting ? "mount" : "umount",
                 output[0] ? output : "no output", (status >> 8) & 0xff);
        fprintf(stderr, "openvm-tools: %s\n", reason);
        shared_response(fd, cid, reason, NULL);
        return;
    }
    if (!mounting) {
        fprintf(stderr, "openvm-tools: shared folder unmounted at %s\n", path);
        shared_response(fd, cid, NULL, NULL);
        return;
    }
    fprintf(stderr, "openvm-tools: shared folder mounted at %s\n", path);
    if (!probe[0]) {
        shared_response(fd, cid, NULL, NULL);
        return;
    }
    char file[512];
    snprintf(file, sizeof file, "%s/%s", path, probe);
    FILE *f = fopen(file, "rb");
    if (!f) {
        char msg[256];
        snprintf(msg, sizeof msg, "probe file is not readable through the share (%s)",
                 strerror(errno));
        shared_response(fd, cid, msg, NULL);
        return;
    }
    char content[1024];
    size_t cn = fread(content, 1, sizeof content - 1, f);
    fclose(f);
    content[cn] = '\0';
    shared_response(fd, cid, NULL, content);
}
