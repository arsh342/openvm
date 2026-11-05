/* ---------- handlers ----------------------------------------------------- */

static void handle_hello(SOCKET fd, uint64_t cid) {
    struct ovmc_out w;
    ovmc_out_init(&w);
    ovmc_whdr(&w, 5, 3);
    ovmc_wtext(&w, "accepted");
    ovmc_wbool(&w, 1);
    ovmc_wtext(&w, "version");
    ovmc_wuint(&w, PRODUCT_VERSION);
    ovmc_wtext(&w, "id");
    ovmc_wuint(&w, cid);
    if (w.ok)
        write_reply(fd, T_HELLO_REPLY, w.b, w.n);
}

/* echoRequest: echo the payload back with the same body, as echoReply. */
static void handle_echo(SOCKET fd, const uint8_t *body, size_t len, uint64_t cid) {
    /* The reply carries the request body verbatim, with the id re-appended
     * last. Rebuilding is simpler and safer than splicing. */
    struct ovmc_out w;
    ovmc_out_init(&w);
    struct ovmc_pair pairs[OVMC_MAX_PAIRS];
    uint64_t ignored = 0;
    long n = ovmc_walk_map(body, len, pairs, OVMC_MAX_PAIRS, &ignored);
    if (n < 0) {
        emit_error(fd, cid, OVMC_ERR_BAD_PAYLOAD, "echo body is not a map");
        return;
    }
    ovmc_whdr(&w, 5, (uint64_t)n);
    for (long i = 0; i < n; i++) {
        const struct ovmc_pair *p = &pairs[i];
        const uint8_t *k = NULL;
        size_t klen = 0;
        if (!ovmc_text_span(body + p->k0, p->k1 - p->k0, &k, &klen))
            continue;
        if (klen == 2 && ovmc_memcmp(k, "id", 2) == 0)
            continue; /* re-appended last */
        ovmc_wtextn(&w, k, klen);
        for (size_t j = p->v0; j < p->v1; j++)
            ovmc_w8(&w, body[j]);
    }
    ovmc_wtext(&w, "id");
    ovmc_wuint(&w, cid);
    if (w.ok)
        write_reply(fd, T_ECHO_REPLY, w.b, w.n);
}

static void handle_clipboard(SOCKET fd, const uint8_t *body, const struct ovmc_pair *pairs,
                             size_t count, uint64_t cid) {
    const struct ovmc_pair *op = ovmc_find(body, pairs, count, "op");
    const uint8_t *optext = NULL;
    size_t oplen = 0;
    if (op == NULL || !ovmc_text_span(body + op->v0, op->v1 - op->v0, &optext, &oplen)) {
        emit_error(fd, cid, OVMC_ERR_BAD_PAYLOAD, "clipboard request needs op");
        return;
    }

    struct ovmc_out w;
    ovmc_out_init(&w);

    if (oplen == 4 && ovmc_memcmp(optext, "read", 4) == 0) {
        static char buf[OVMC_MAX_PAYLOAD / 2];
        size_t len = 0;
        if (!clipboard_read(buf, sizeof buf, &len)) {
            ovmc_whdr(&w, 5, 2);
            ovmc_wtext(&w, "error");
            ovmc_wtext(&w, g_helper_error ? g_helper_error : "no clipboard backend");
            ovmc_wtext(&w, "id");
            ovmc_wuint(&w, cid);
            if (w.ok)
                write_reply(fd, T_CLIPBOARD_REPLY, w.b, w.n);
            return;
        }
        ovmc_whdr(&w, 5, 2);
        ovmc_wtext(&w, "text");
        ovmc_wtextn(&w, (const uint8_t *)buf, len);
        ovmc_wtext(&w, "id");
        ovmc_wuint(&w, cid);
        if (w.ok)
            write_reply(fd, T_CLIPBOARD_REPLY, w.b, w.n);
        return;
    }

    if (oplen == 5 && ovmc_memcmp(optext, "write", 5) == 0) {
        const struct ovmc_pair *tp = ovmc_find(body, pairs, count, "text");
        const uint8_t *text = NULL;
        size_t tlen = 0;
        if (tp == NULL || !ovmc_text_span(body + tp->v0, tp->v1 - tp->v0, &text, &tlen)) {
            emit_error(fd, cid, OVMC_ERR_BAD_PAYLOAD, "clipboard write needs text");
            return;
        }
        if (!clipboard_write((const char *)text, tlen)) {
            ovmc_whdr(&w, 5, 2);
            ovmc_wtext(&w, "error");
            ovmc_wtext(&w, g_helper_error ? g_helper_error : "no clipboard backend");
            ovmc_wtext(&w, "id");
            ovmc_wuint(&w, cid);
            if (w.ok)
                write_reply(fd, T_CLIPBOARD_REPLY, w.b, w.n);
            return;
        }
        ovmc_whdr(&w, 5, 1);
        ovmc_wtext(&w, "id");
        ovmc_wuint(&w, cid);
        if (w.ok)
            write_reply(fd, T_CLIPBOARD_REPLY, w.b, w.n);
        return;
    }

    emit_error(fd, cid, OVMC_ERR_BAD_PAYLOAD, "clipboard op must be read or write");
}

#ifdef OPENVM_REAL_WIN32
/* Apply a Windows time zone by key name with tzutil, the OS's own tool.
 *
 * SetDynamicTimeZoneInformation needs every field filled in, not just the key name.
 * tzutil looks the zone up in the registry itself, and its exit code is the truth. */
static int set_windows_timezone(const wchar_t *win_tz) {
    WCHAR cmd[200];
    const WCHAR *prefix = L"tzutil.exe /s \"";
    size_t n = 0;
    for (const WCHAR *p = prefix; *p && n < 190; p++)
        cmd[n++] = *p;
    for (const wchar_t *p = win_tz; *p && n < 197; p++)
        cmd[n++] = *p;
    cmd[n++] = L'"';
    cmd[n] = 0;
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    ovmc_memset_zero(&si, sizeof si);
    ovmc_memset_zero(&pi, sizeof pi);
    si.cb = sizeof si;
    if (!CreateProcessW(NULL, cmd, NULL, NULL, 0, CREATE_NO_WINDOW, NULL, NULL, &si, &pi))
        return 0;
    DWORD code = 1;
    int ok = WaitForSingleObject(pi.hProcess, 10000) == WAIT_OBJECT_0 &&
             GetExitCodeProcess(pi.hProcess, &code) && code == 0;
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return ok;
}
#endif
