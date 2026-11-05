/* ---------- dynamic resolution (24/25) -----------------------------------
 * The host resizes its window; the guest modesets. Linux does that through
 * DRM (drmModeSetCrtc) or, in a session, xrandr/wlr-randr. The agent validates
 * the request and reports the mode it holds, which is not necessarily the one
 * asked for. */
static uint64_t g_displayW = 1920, g_displayH = 1080, g_displayScale = 0;

static void display_response(int fd, uint64_t cid, const char *error) {
    struct ovmc_out w;
    w.n = 0;
    w.ok = 1;
    ovmc_whdr(&w, 5, (error ? 4 : 3) + (g_displayScale ? 1 : 0));
    ovmc_wtext(&w, "width");
    ovmc_wuint(&w, g_displayW);
    ovmc_wtext(&w, "height");
    ovmc_wuint(&w, g_displayH);
    if (g_displayScale) {
        ovmc_wtext(&w, "scale");
        ovmc_wuint(&w, g_displayScale);
    }
    if (error) {
        ovmc_wtext(&w, "error");
        ovmc_wtext(&w, error);
    }
    ovmc_wtext(&w, "id");
    ovmc_wuint(&w, cid);
    if (w.ok)
        write_reply(fd, T_DISPLAY_REPLY, w.b, w.n);
}

/* The display belongs to the session's X server, so the work is in a script
 * (tools/guest/openvm-display-backend.sh). It prints the mode X holds afterwards:
 * that, not the request, is what the host is told. */
#ifndef OPENVM_DISPLAY_BACKEND
#define OPENVM_DISPLAY_BACKEND "/opt/openvm/openvm-display-backend.sh"
#endif

static int display_backend(const char *args, char *out, size_t cap) {
    char cmd[256];
    snprintf(cmd, sizeof cmd, OPENVM_DISPLAY_BACKEND " %s 2>&1", args);
    FILE *pipe = popen(cmd, "r");
    if (pipe == NULL)
        return 0;
    size_t got = fread(out, 1, cap - 1, pipe);
    out[got] = '\0';
    trim_eol(out);
    return pclose(pipe) == 0;
}

static void handle_display(int fd, const uint8_t *body, const struct ovmc_pair *pairs, size_t count,
                           uint64_t cid) {
    char said[200];
    char op[16] = "set";
    if (find_pair(body, pairs, count, "op") != NULL &&
        !text_field(body, pairs, count, "op", op, sizeof op)) {
        display_response(fd, cid, "display request has no usable op");
        return;
    }
    if (strcmp(op, "capture") == 0) {
        if (!display_backend("capture", said, sizeof said)) {
            display_response(fd, cid, said[0] ? said : "screen capture failed");
            return;
        }
        struct ovmc_out *w = malloc(sizeof *w);
        if (!w)
            return;
        w->n = 0;
        w->ok = 1;
        ovmc_whdr(w, 5, 2);
        ovmc_wtext(w, "capture");
        ovmc_wtext(w, said);
        ovmc_wtext(w, "id");
        ovmc_wuint(w, cid);
        if (w->ok)
            write_reply(fd, T_DISPLAY_REPLY, w->b, w->n);
        free(w);
        return;
    }
    uint64_t width = 0, height = 0;
    if (!decode_uint_pair(body, find_pair(body, pairs, count, "width"), &width) ||
        !decode_uint_pair(body, find_pair(body, pairs, count, "height"), &height)) {
        display_response(fd, cid, "display request needs width and height");
        return;
    }
    /* Bounds: a modeset outside these is a host bug, not a request. */
    if (width < 640 || height < 480 || width > 7680 || height > 4320) {
        display_response(fd, cid, "mode out of range");
        return;
    }
    uint64_t scale = 0;
    const struct ovmc_pair *scale_pair = find_pair(body, pairs, count, "scale");
    if (scale_pair != NULL &&
        (!decode_uint_pair(body, scale_pair, &scale) || scale < 1 || scale > 3)) {
        display_response(fd, cid, "scale must be 1, 2 or 3");
        return;
    }
    char args[64];
    snprintf(args, sizeof args, "set %lu %lu %lu", (unsigned long)width, (unsigned long)height,
             (unsigned long)scale);
    unsigned long held_w = 0, held_h = 0, held_scale = 0;
    if (!display_backend(args, said, sizeof said) ||
        sscanf(said, "%lux%lu@%lu", &held_w, &held_h, &held_scale) < 2) {
        fprintf(stderr, "openvm-tools: display %s failed: %s\n", args, said);
        display_response(fd, cid, said[0] ? said : "the display backend failed");
        return;
    }
    g_displayW = held_w;
    g_displayH = held_h;
    g_displayScale = held_scale;
    fprintf(stderr, "openvm-tools: display holds %lux%lu at scale %lu\n", held_w, held_h,
            held_scale);
    display_response(fd, cid, NULL);
}
