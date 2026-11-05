/* Answer the host's suspend handshake: an empty body means the guest flushed. */
static void suspend_response(int fd, uint64_t cid, const char *error) {
    struct ovmc_out *w = malloc(sizeof *w); /* heap: avoids a 1 MiB stack frame on
                                          worker threads (handle_file does same) */
    if (!w)
        return;
    w->n = 0;
    w->ok = 1;
    ovmc_whdr(w, 5, error ? 2 : 1);
    if (error) {
        ovmc_wtext(w, "error");
        ovmc_wtext(w, error);
    }
    ovmc_wtext(w, "id");
    ovmc_wuint(w, cid);
    if (w->ok)
        write_reply(fd, T_SUSPEND_REPLY, w->b, w->n);
    free(w);
}

/* The host is about to sleep: flush the guest's files so the disk state is
 * consistent when the host wakes the VM again. */
static void handle_suspend(int fd, const uint8_t *body, const struct ovmc_pair *pairs, size_t count,
                           uint64_t cid) {
    char op[16];
    if (!text_field(body, pairs, count, "op", op, sizeof op)) {
        suspend_response(fd, cid, "suspend request has no usable op");
        return;
    }
    if (strcmp(op, "shutdown") == 0) {
        /* The host's stop: the framework's power button does nothing here, so
         * an orderly shutdown has to be asked for from inside. The reply goes
         * first; poweroff follows once it has left. */
        fprintf(stderr, "openvm-tools: shutdown requested by the host\n");
        suspend_response(fd, cid, NULL);
        if (system("(sleep 1; " OPENVM_POWEROFF ") >/dev/null 2>&1 &") != 0)
            fprintf(stderr, "openvm-tools: could not start poweroff\n");
        return;
    }
    if (strcmp(op, "quiesce") != 0) {
        suspend_response(fd, cid, "unknown suspend op");
        return;
    }
    char output[256];
    output[0] = '\0';
    FILE *p = popen("sync 2>&1", "r");
    if (p) {
        size_t n = fread(output, 1, sizeof output - 1, p);
        output[n] = '\0';
        trim_eol(output);
        if (pclose(p) != 0) {
            char reason[320];
            snprintf(reason, sizeof reason, "could not flush the guest (%s)",
                     output[0] ? output : "sync failed");
            fprintf(stderr, "openvm-tools: %s\n", reason);
            suspend_response(fd, cid, reason);
            return;
        }
    }
    fprintf(stderr, "openvm-tools: guest quiesced for the host sleep\n");
    suspend_response(fd, cid, NULL);
}

/* Shared folders over virtio-fs.
 *
 * The host attaches one virtio-fs device, tag "openvm", whose root holds one
 * directory per share (a VZMultipleDirectoryShare keyed by share name). The
 * agent mounts the tag once at /run/openvm-fs and bind-mounts the requested
 * share onto the guest path. The host can change the share set while the VM
 * runs; if a newly added name is not visible yet, the tag is remounted once. */
#define OPENVM_FS_TAG "openvm"
#ifndef OPENVM_FS_ROOT
#define OPENVM_FS_ROOT "/run/openvm-fs"
#endif
