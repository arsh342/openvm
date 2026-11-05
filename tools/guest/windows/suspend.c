/* suspendRequest {op:"quiesce"}: flush before the host sleeps. Windows has no
 * sync(2); FlushFileBuffers on the volume handles is the equivalent, and
 * flushing the staging directory is enough for the agent's own writes. */
#ifdef OPENVM_REAL_WIN32
/* The host's stop. The framework's power button never reaches Windows on this
 * virtual hardware, so an orderly shutdown has to be asked for from inside. */
static int shutdown_guest(void) {
    HANDLE token = NULL;
    TOKEN_PRIVILEGES tp;
    ovmc_memset_zero(&tp, sizeof tp);
    tp.PrivilegeCount = 1;
    tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &token))
        return 0;
    int ok = LookupPrivilegeValueW(NULL, L"SeShutdownPrivilege", &tp.Privileges[0].Luid) &&
             AdjustTokenPrivileges(token, FALSE, &tp, 0, NULL, NULL) &&
             GetLastError() == ERROR_SUCCESS;
    CloseHandle(token);
    if (!ok)
        return 0;
    /* A second's grace lets the reply leave; force, or an unsaved document in
     * the autologon session would hold the shutdown open forever. */
    return InitiateSystemShutdownExW(NULL, NULL, 1, TRUE, FALSE,
                                     SHTDN_REASON_MAJOR_OTHER | SHTDN_REASON_FLAG_PLANNED);
}
#endif

static void handle_suspend(SOCKET fd, const uint8_t *body, const struct ovmc_pair *pairs,
                           size_t count, uint64_t cid) {
    const struct ovmc_pair *op = ovmc_find(body, pairs, count, "op");
    const uint8_t *optext = NULL;
    size_t oplen = 0;
    if (op != NULL && ovmc_text_span(body + op->v0, op->v1 - op->v0, &optext, &oplen) &&
        oplen == 8 && ovmc_memcmp(optext, "shutdown", 8) == 0) {
        struct ovmc_out *r = malloc(sizeof *r);
        if (r == NULL)
            return;
        ovmc_out_init(r);
#ifdef OPENVM_REAL_WIN32
        int down = shutdown_guest();
        unsigned long why = down ? 0 : (unsigned long)GetLastError();
        agent_log("shutdown requested by the host: %s (%lu)", down ? "started" : "refused", why);
#else
        int down = 0;
        unsigned long why = 0;
#endif
        ovmc_whdr(r, 5, down ? 1 : 2);
        if (!down) {
            char reason[64];
            int n = 0;
            for (const char *p = "the guest refused to shut down, error "; *p; p++)
                reason[n++] = *p;
            char digits[12];
            int d = 0;
            do {
                digits[d++] = (char)('0' + why % 10);
                why /= 10;
            } while (why && d < 11);
            while (d)
                reason[n++] = digits[--d];
            reason[n] = '\0';
            ovmc_wtext(r, "error");
            ovmc_wtext(r, reason);
        }
        ovmc_wtext(r, "id");
        ovmc_wuint(r, cid);
        if (r->ok)
            write_reply(fd, T_SUSPEND_REPLY, r->b, r->n);
        free(r);
        return;
    }

    const char *flush_error = NULL;
#ifdef OPENVM_REAL_WIN32
    /* Flush the system volume. FlushFileBuffers needs write access, so a directory
     * handle will not do, and a volume handle needs the SYSTEM service account. */
    HANDLE h = CreateFileW(L"\\\\.\\C:", GENERIC_READ | GENERIC_WRITE,
                           FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
    if (h == INVALID_HANDLE_VALUE) {
        flush_error = "could not open the system volume to flush it";
    } else {
        if (!FlushFileBuffers(h))
            flush_error = "flushing the system volume failed";
        CloseHandle(h);
    }
#endif
    if (flush_error != NULL) {
        struct ovmc_out e;
        ovmc_out_init(&e);
        ovmc_whdr(&e, 5, 2);
        ovmc_wtext(&e, "error");
        ovmc_wtext(&e, flush_error);
        ovmc_wtext(&e, "id");
        ovmc_wuint(&e, cid);
        if (e.ok)
            write_reply(fd, T_SUSPEND_REPLY, e.b, e.n);
        return;
    }

    struct ovmc_out w;
    ovmc_out_init(&w);
    ovmc_whdr(&w, 5, 1);
    ovmc_wtext(&w, "id");
    ovmc_wuint(&w, cid);
    if (w.ok)
        write_reply(fd, T_SUSPEND_REPLY, w.b, w.n);
}
