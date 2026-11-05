/* ---------- files dragged into the guest (18/19) ---------------------------
 * The host stages the items as a read-only share (DragControl.swift)
 * and a helper in the user's session copies them from the VirtIO-FS drive to their
 * Desktop. It runs as that user, and in the background: a large tree must not
 * hold the channel, and the host polls `status` for the outcome. */
#define DROP_ITEMS_MAX 64
#define DROP_NAME_MAX 256

static void drag_reply(SOCKET fd, uint64_t cid, int accepted, const char *error) {
    static struct ovmc_out w;
    ovmc_out_init(&w);
    ovmc_whdr(&w, 5, error ? 3 : 2);
    ovmc_wtext(&w, "accepted");
    ovmc_wbool(&w, accepted);
    if (error) {
        ovmc_wtext(&w, "error");
        ovmc_wtext(&w, error);
    }
    ovmc_wtext(&w, "id");
    ovmc_wuint(&w, cid);
    if (w.ok)
        write_reply(fd, T_DRAG_REPLY, w.b, w.n);
}

/* `items` as newline-separated UTF-8, for the helper's stdin. 0 on any bad name. */
static size_t drop_item_lines(const uint8_t *p, size_t span, char *out, size_t cap) {
    if (span < 1 || (p[0] >> 5) != 4)
        return 0;
    size_t count, head;
    uint8_t minor = p[0] & 0x1f;
    if (minor < 24) {
        count = minor;
        head = 1;
    } else if (minor == 24 && span >= 2) {
        count = p[1];
        head = 2;
    } else {
        return 0;
    }
    if (count == 0 || count > DROP_ITEMS_MAX)
        return 0;
    struct ovmc_cur c = {p, span, head, 1};
    size_t used = 0;
    for (size_t i = 0; i < count; i++) {
        size_t start = c.i;
        ovmc_parse_val(&c);
        const uint8_t *text = NULL;
        size_t len = 0;
        if (!c.ok || !ovmc_text_span(p + start, c.i - start, &text, &len) ||
            !ovmc_valid_windows_item(text, len) || used + len + 1 > cap)
            return 0;
        ovmc_memcpy(out + used, text, len);
        used += len;
        out[used++] = '\n';
    }
    return c.i == span ? used : 0;
}

#ifdef OPENVM_REAL_WIN32
static struct {
    int running;
    struct session_child child;
    char out[DROP_ITEMS_MAX * (DROP_NAME_MAX + 32)];
    size_t got;
} g_drop;

static void drag_collect(void) {
    DWORD ready = 0;
    while (g_drop.got + 1 < sizeof g_drop.out &&
           PeekNamedPipe(g_drop.child.out_r, NULL, 0, NULL, &ready, NULL) && ready > 0) {
        DWORD did = 0;
        DWORD want = (DWORD)(sizeof g_drop.out - 1 - g_drop.got);
        if (want > ready)
            want = ready;
        if (!ReadFile(g_drop.child.out_r, g_drop.out + g_drop.got, want, &did, NULL) || did == 0)
            break;
        g_drop.got += did;
    }
}

static void drag_start(SOCKET fd, const uint8_t *body, const struct ovmc_pair *pairs, size_t count,
                       uint64_t cid) {
    static char lines[DROP_ITEMS_MAX * DROP_NAME_MAX];
    if (g_drop.running) {
        drag_reply(fd, cid, 0, "a drop is already running");
        return;
    }
    const struct ovmc_pair *list = ovmc_find(body, pairs, count, "items");
    size_t used =
        list ? drop_item_lines(body + list->v0, list->v1 - list->v0, lines, sizeof lines) : 0;
    if (used == 0) {
        drag_reply(fd, cid, 0, "drop needs a list of valid item names");
        return;
    }
    const struct ovmc_pair *sp = ovmc_find(body, pairs, count, "share");
    const uint8_t *share = NULL;
    size_t share_len = 0;
    if (sp == NULL || !ovmc_text_span(body + sp->v0, sp->v1 - sp->v0, &share, &share_len) ||
        share_len == 0 || share_len > 40) {
        drag_reply(fd, cid, 0, "drop has no usable share");
        return;
    }
    WCHAR mode[64] = L"--drop ";
    size_t m = 7;
    for (size_t i = 0; i < share_len; i++) {
        uint8_t c = share[i];
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'))) {
            drag_reply(fd, cid, 0, "drop has no usable share");
            return;
        }
        mode[m++] = (WCHAR)c;
    }
    mode[m] = 0;
    g_helper_error = NULL;
    if (!start_in_user_session(mode, &g_drop.child)) {
        drag_reply(fd, cid, 0, g_helper_error ? g_helper_error : "could not start the copy");
        return;
    }
    child_write_all(&g_drop.child, (const uint8_t *)lines, used);
    g_drop.running = 1;
    g_drop.got = 0;
    agent_log("drop started");
    drag_reply(fd, cid, 1, NULL);
}

static void drag_status(SOCKET fd, uint64_t cid) {
    if (!g_drop.running) {
        drag_reply(fd, cid, 0, "no drop is running");
        return;
    }
    static struct ovmc_out w;
    ovmc_out_init(&w);
    drag_collect();
    if (WaitForSingleObject(g_drop.child.process, 0) != WAIT_OBJECT_0) {
        ovmc_whdr(&w, 5, 3);
        ovmc_wtext(&w, "accepted");
        ovmc_wbool(&w, 1);
        ovmc_wtext(&w, "done");
        ovmc_wbool(&w, 0);
    } else {
        drag_collect();
        DWORD code = 1;
        GetExitCodeProcess(g_drop.child.process, &code);
        CloseHandle(g_drop.child.thread);
        CloseHandle(g_drop.child.process);
        CloseHandle(g_drop.child.out_r);
        g_drop.running = 0;
        g_drop.out[g_drop.got] = 0;
        const char *placed[DROP_ITEMS_MAX];
        const char *error = NULL;
        size_t n = 0;
        uint64_t bytes = 0;
        unsigned long retries = 0;
        char *line = g_drop.out;
        while (*line) {
            char *end = line;
            while (*end && *end != '\n')
                end++;
            int more = *end != 0;
            *end = 0;
            if (line[0] == 'o' && line[1] == 'k' && line[2] == ' ' && n < DROP_ITEMS_MAX) {
                char *rest = NULL;
                bytes += strtoull(line + 3, &rest, 10);
                placed[n++] = rest + 1;
            } else if (line[0] == 'e' && line[1] == 'r' && line[2] == 'r' && line[3] == ' ') {
                error = line + 4;
            } else if (ovmc_memcmp(line, "retries ", 8) == 0) {
                retries = strtoul(line + 8, NULL, 10);
            }
            line = more ? end + 1 : end;
        }
        if (error == NULL && code != 0)
            error = "the copy stopped early";
        ovmc_whdr(&w, 5, error ? 6 : 5);
        ovmc_wtext(&w, "accepted");
        ovmc_wbool(&w, 1);
        ovmc_wtext(&w, "done");
        ovmc_wbool(&w, 1);
        ovmc_wtext(&w, "placed");
        ovmc_whdr(&w, 4, n);
        for (size_t i = 0; i < n; i++)
            ovmc_wtext(&w, placed[i]);
        ovmc_wtext(&w, "bytes");
        ovmc_wuint(&w, bytes);
        if (error) {
            ovmc_wtext(&w, "error");
            ovmc_wtext(&w, error);
        }
        agent_log("drop finished: %lu item(s), %lu read retries%s%s", (unsigned long)n, retries,
                  error ? ", " : "", error ? error : "");
    }
    ovmc_wtext(&w, "id");
    ovmc_wuint(&w, cid);
    if (w.ok)
        write_reply(fd, T_DRAG_REPLY, w.b, w.n);
}
#endif

static void handle_drag(SOCKET fd, const uint8_t *body, const struct ovmc_pair *pairs, size_t count,
                        uint64_t cid) {
    const struct ovmc_pair *op = ovmc_find(body, pairs, count, "op");
    const uint8_t *optext = NULL;
    size_t oplen = 0;
    if (op == NULL || !ovmc_text_span(body + op->v0, op->v1 - op->v0, &optext, &oplen)) {
        emit_error(fd, cid, OVMC_ERR_BAD_PAYLOAD, "drag request needs op");
        return;
    }
    if (oplen == 5 && ovmc_memcmp(optext, "leave", 5) == 0) {
        drag_reply(fd, cid, 1, NULL);
#ifdef OPENVM_REAL_WIN32
    } else if (oplen == 5 && ovmc_memcmp(optext, "enter", 5) == 0) {
        HANDLE user = NULL;
        DWORD session = WTSGetActiveConsoleSessionId();
        if (session != 0xFFFFFFFFu && WTSQueryUserToken(session, &user)) {
            CloseHandle(user);
            drag_reply(fd, cid, 1, NULL);
        } else {
            drag_reply(fd, cid, 0, "no user is logged on to the guest console");
        }
    } else if (oplen == 4 && ovmc_memcmp(optext, "drop", 4) == 0) {
        drag_start(fd, body, pairs, count, cid);
    } else if (oplen == 6 && ovmc_memcmp(optext, "status", 6) == 0) {
        drag_status(fd, cid);
#endif
    } else {
        drag_reply(fd, cid, 0, "drag op must be enter, leave, drop or status");
    }
}
