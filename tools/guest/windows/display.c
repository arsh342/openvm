/* ---------- dynamic resolution (24/25) -----------------------------------
 * The host resizes its window; the guest modesets. On Windows that is
 * ChangeDisplaySettingsEx against the virtual display. The agent validates the
 * request and reports the mode it actually holds, which is not necessarily the
 * one asked for. */
static uint64_t g_displayW = 1920, g_displayH = 1080, g_displayScale = 0;

/* Windows also drives openVM's boot frame buffer through the Basic Display Driver, as a second display
 * nobody can see (docs/evidence/windows-second-display-2026-11-11.md). The helper switches it off, but
 * only while the virtio display is active: if viogpudo has failed, the Basic Display is all there is. */

/* Whether an adapter's device path names the virtio GPU, PCI 1af4:1050. ASCII, any case. */
static int display_is_virtio_adapter(const char *path) {
    static const char want[] = "VEN_1AF4&DEV_1050";
    if (path == NULL)
        return 0;
    for (size_t i = 0; path[i] != '\0'; i++) {
        size_t k = 0;
        while (want[k] != '\0') {
            char c = path[i + k];
            if (c >= 'a' && c <= 'z')
                c = (char)(c - 'a' + 'A');
            if (c != want[k])
                break;
            k++;
        }
        if (want[k] == '\0')
            return 1;
    }
    return 0;
}

/* Given which active displays are on the virtio GPU, marks the ones to keep. Returns how many to keep,
 * or 0 when nothing should change: no virtio display is active, or nothing else is. */
static size_t display_choose_kept(const int *is_virtio, size_t count, int *keep) {
    size_t virtio = 0;
    for (size_t i = 0; i < count; i++)
        if (is_virtio[i])
            virtio++;
    if (virtio == 0 || virtio == count)
        return 0;
    for (size_t i = 0; i < count; i++)
        keep[i] = is_virtio[i] ? 1 : 0;
    return virtio;
}

static void display_reply(SOCKET fd, uint64_t cid, const char *error) {
    static struct ovmc_out w;
    ovmc_out_init(&w);
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

#ifdef OPENVM_REAL_WIN32
/* The screen belongs to the logged-on session, so the helper grabs it into the
 * spool (the one folder users can write); the file service reads the staging
 * directory, so the agent moves it there for `file pull`. */
static void display_capture(SOCKET fd, uint64_t cid) {
    uint8_t said[160];
    size_t got = 0;
    WCHAR from[WIN_PATH_MAX], to[WIN_PATH_MAX];
    g_helper_error = NULL;
    if (!run_in_user_session(L"--capture", NULL, 0, said, sizeof said, &got)) {
        display_reply(fd, cid, g_helper_error ? g_helper_error : "screen capture failed");
        return;
    }
    if (!spool_path("capture.bmp", from, WIN_PATH_MAX) ||
        !share_path("capture.bmp", to, WIN_PATH_MAX) ||
        !MoveFileExW(from, to, MOVEFILE_REPLACE_EXISTING | MOVEFILE_COPY_ALLOWED)) {
        display_reply(fd, cid, "could not stage the capture");
        return;
    }
    static struct ovmc_out w;
    ovmc_out_init(&w);
    ovmc_whdr(&w, 5, 2);
    ovmc_wtext(&w, "capture");
    ovmc_wtext(&w, "capture.bmp");
    ovmc_wtext(&w, "id");
    ovmc_wuint(&w, cid);
    if (w.ok)
        write_reply(fd, T_DISPLAY_REPLY, w.b, w.n);
}
#endif

static void handle_display(SOCKET fd, const uint8_t *body, const struct ovmc_pair *pairs,
                           size_t count, uint64_t cid) {
    const struct ovmc_pair *op = ovmc_find(body, pairs, count, "op");
    const uint8_t *optext = NULL;
    size_t oplen = 0;
    if (op != NULL && ovmc_text_span(body + op->v0, op->v1 - op->v0, &optext, &oplen) &&
        oplen == 7 && ovmc_memcmp(optext, "capture", 7) == 0) {
#ifdef OPENVM_REAL_WIN32
        display_capture(fd, cid);
#else
        display_reply(fd, cid, "capture needs the real Win32 build");
#endif
        return;
    }
    const struct ovmc_pair *wp = ovmc_find(body, pairs, count, "width");
    const struct ovmc_pair *hp = ovmc_find(body, pairs, count, "height");
    uint64_t width = 0, height = 0;
    if (wp == NULL || hp == NULL || !ovmc_uint_from(body + wp->v0, wp->v1 - wp->v0, &width) ||
        !ovmc_uint_from(body + hp->v0, hp->v1 - hp->v0, &height)) {
        emit_error(fd, cid, OVMC_ERR_BAD_PAYLOAD, "display request needs width and height");
        return;
    }
    /* Bounds: a modeset outside these is a host bug, not a request. */
    if (width < 640 || height < 480 || width > 7680 || height > 4320) {
        display_reply(fd, cid, "mode out of range");
        return;
    }
    uint64_t scale = 0;
    const struct ovmc_pair *sp = ovmc_find(body, pairs, count, "scale");
    if (sp != NULL &&
        (!ovmc_uint_from(body + sp->v0, sp->v1 - sp->v0, &scale) || scale < 1 || scale > 3)) {
        display_reply(fd, cid, "scale must be 1, 2 or 3");
        return;
    }
#ifdef OPENVM_REAL_WIN32
    /* The display is the session's: the helper applies the mode there and
     * prints the mode Windows holds afterwards, which is what the host hears. */
    WCHAR mode[48];
    swprintf(mode, sizeof mode / sizeof mode[0], L"--display %lu %lu %lu", (unsigned long)width,
             (unsigned long)height, (unsigned long)scale);
    static uint8_t said[256];
    size_t got = 0;
    g_helper_error = NULL;
    if (!run_in_user_session(mode, NULL, 0, said, sizeof said - 1, &got)) {
        agent_log("display %lux%lu: %s", (unsigned long)width, (unsigned long)height,
                  g_helper_error ? g_helper_error : "helper failed");
        display_reply(fd, cid, g_helper_error ? g_helper_error : "the display helper failed");
        return;
    }
    said[got] = 0;
    unsigned long held_w = 0, held_h = 0, held_scale = 0;
    if (sscanf((const char *)said, "%lux%lu@%lu", &held_w, &held_h, &held_scale) < 2) {
        display_reply(fd, cid, "the display helper gave no mode");
        return;
    }
    g_displayW = held_w;
    g_displayH = held_h;
    g_displayScale = held_scale;
    agent_log("display holds %lux%lu at scale %lu (%s)", held_w, held_h, held_scale,
              (const char *)said);
    display_reply(fd, cid, NULL);
#else
    display_reply(fd, cid, "display needs the real Win32 build");
#endif
}
