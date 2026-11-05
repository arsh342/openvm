/* ---------- printers (20/21) ---------------------------------------------
 * The host publishes its printers (sync); each becomes a queue on
 * the stock Microsoft Print to PDF driver whose port is a file in the spool, so
 * no driver of ours is installed (tools/windows/printers.ps1 does the queues).
 * The host collects from the spool (jobs, fetch, done): it is the only opener
 * of the channel, so nothing is pushed.
 *
 * A file port has one fixed path per queue. The spooler holds it open until the
 * job is finished, so renaming it to PRINTER--N.pdf is both how a finished job
 * is told from a running one and what frees the path for the next job. */
#define WIN_SPOOL_DIR L"C:\\openvm\\spool"
#define PRINTER_MAX 32
#define PRINTER_NAME_MAX 97
#define PRINT_JOBS_MAX 16
#define PRINT_CHUNK_MAX (64 * 1024)
#define PRINT_JOB_NAME_MAX 160

/* The same alphabet the host checks: names reach a PowerShell argument. */
static int valid_printer_name(const char *s) {
    size_t n = ovmc_strlen(s);
    if (n == 0 || n >= PRINTER_NAME_MAX || s[0] == '.' || s[0] == '-')
        return 0;
    return safe_component((const uint8_t *)s, n, PRINTER_NAME_MAX - 1, 0);
}

/* Decodes `printers`: a definite array of valid names. -1 on anything else. */
static long printer_name_array(const uint8_t *p, size_t span, char out[][PRINTER_NAME_MAX],
                               size_t cap) {
    if (span < 1 || (p[0] >> 5) != 4)
        return -1;
    size_t count, head;
    uint8_t minor = p[0] & 0x1f;
    if (minor < 24) {
        count = minor;
        head = 1;
    } else if (minor == 24 && span >= 2) {
        count = p[1];
        head = 2;
    } else {
        return -1;
    }
    if (count > cap)
        return -1;
    struct ovmc_cur c = {p, span, head, 1};
    for (size_t i = 0; i < count; i++) {
        size_t start = c.i;
        ovmc_parse_val(&c);
        const uint8_t *text = NULL;
        size_t len = 0;
        if (!c.ok || !ovmc_text_span(p + start, c.i - start, &text, &len) ||
            len >= PRINTER_NAME_MAX)
            return -1;
        ovmc_memcpy(out[i], text, len);
        out[i][len] = '\0';
        if (!valid_printer_name(out[i]))
            return -1;
    }
    return c.i == span ? (long)count : -1;
}

static void printer_reply(SOCKET fd, uint64_t cid, const char *error,
                          char names[][PRINTER_NAME_MAX], long count) {
    static struct ovmc_out w;
    ovmc_out_init(&w);
    ovmc_whdr(&w, 5, (error || count >= 0) ? 2 : 1);
    if (error) {
        ovmc_wtext(&w, "error");
        ovmc_wtext(&w, error);
    } else if (count >= 0) {
        ovmc_wtext(&w, "printers");
        ovmc_whdr(&w, 4, (uint64_t)count);
        for (long i = 0; i < count; i++)
            ovmc_wtext(&w, names[i]);
    }
    ovmc_wtext(&w, "id");
    ovmc_wuint(&w, cid);
    if (w.ok)
        write_reply(fd, T_PRINTER_REPLY, w.b, w.n);
}

/* Spool files are ASCII by construction; anything else is not ours. */
static int spool_path(const char *name, WCHAR *out, size_t cap) {
    size_t n = 0;
    for (const WCHAR *p = WIN_SPOOL_DIR L"\\"; *p; p++) {
        if (n + 1 >= cap)
            return 0;
        out[n++] = *p;
    }
    for (const char *p = name; *p; p++) {
        if (n + 1 >= cap)
            return 0;
        out[n++] = (WCHAR)(unsigned char)*p;
    }
    out[n] = 0;
    return 1;
}

#ifdef OPENVM_REAL_WIN32
/* Runs a command line, keeps what it prints in `why`, and says whether it exited 0. */
static int run_script(WCHAR *cmd, char *why, size_t why_cap, DWORD timeout_ms) {
    SECURITY_ATTRIBUTES sa = {sizeof sa, NULL, TRUE};
    HANDLE out_r = NULL, out_w = NULL;
    why[0] = '\0';
    if (!CreatePipe(&out_r, &out_w, &sa, 0))
        return 0;
    SetHandleInformation(out_r, HANDLE_FLAG_INHERIT, 0);
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    ovmc_memset_zero(&si, sizeof si);
    ovmc_memset_zero(&pi, sizeof pi);
    si.cb = sizeof si;
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdOutput = out_w;
    si.hStdError = out_w;
    BOOL started =
        CreateProcessW(NULL, cmd, NULL, NULL, TRUE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi);
    CloseHandle(out_w);
    if (!started) {
        CloseHandle(out_r);
        return 0;
    }
    size_t got = 0;
    int finished = read_child(out_r, pi.hProcess, (uint8_t *)why, why_cap - 1, &got, timeout_ms);
    why[got] = '\0';
    CloseHandle(out_r);
    DWORD code = 1;
    if (WaitForSingleObject(pi.hProcess, 2000) != WAIT_OBJECT_0)
        TerminateProcess(pi.hProcess, 1);
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    if (!finished) {
        snprintf(why, why_cap, "the script timed out");
        return 0;
    }
    return code == 0;
}

/* Runs printers.ps1 beside this executable, which makes the queues match. */
static int printer_script(const char *names, char *why, size_t why_cap) {
    WCHAR cmd[8192];
    int n = swprintf(cmd, sizeof cmd / sizeof cmd[0],
                     L"powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass "
                     L"-File C:\\openvm\\printers.ps1 -Names \"%hs\"",
                     names);
    if (n < 0)
        return 0;
    return run_script(cmd, why, why_cap, 45000);
}

/* printers.ps1 takes seconds, and much longer on a first boot. The agent answers one
 * request at a time, so running it here made every other request time out. It runs
 * on its own thread: `sync` answers `pending`, and the host asks again for the
 * result, so a failure still reaches the host and is retried. */
static struct {
    HANDLE thread;
    char names[PRINTER_MAX * PRINTER_NAME_MAX];
    char why[400];
    int ok;
} g_sync;

static DWORD WINAPI printer_sync_thread(LPVOID unused) {
    (void)unused;
    g_sync.ok = printer_script(g_sync.names, g_sync.why, sizeof g_sync.why);
    return 0;
}

static void printer_pending(SOCKET fd, uint64_t cid) {
    static struct ovmc_out w;
    ovmc_out_init(&w);
    ovmc_whdr(&w, 5, 2);
    ovmc_wtext(&w, "pending");
    ovmc_wbool(&w, 1);
    ovmc_wtext(&w, "id");
    ovmc_wuint(&w, cid);
    if (w.ok)
        write_reply(fd, T_PRINTER_REPLY, w.b, w.n);
}
#endif

static void printer_sync(SOCKET fd, const uint8_t *body, const struct ovmc_pair *pairs,
                         size_t count, uint64_t cid) {
    static char wanted[PRINTER_MAX][PRINTER_NAME_MAX];
    const struct ovmc_pair *list = ovmc_find(body, pairs, count, "printers");
    long n =
        list ? printer_name_array(body + list->v0, list->v1 - list->v0, wanted, PRINTER_MAX) : -1;
    if (n < 0) {
        printer_reply(fd, cid, "sync needs a list of valid printer names", NULL, -1);
        return;
    }
    char fallback[PRINTER_NAME_MAX] = "";
    const struct ovmc_pair *dp = ovmc_find(body, pairs, count, "default");
    if (dp != NULL) {
        const uint8_t *text = NULL;
        size_t len = 0;
        if (!ovmc_text_span(body + dp->v0, dp->v1 - dp->v0, &text, &len) ||
            len >= PRINTER_NAME_MAX) {
            printer_reply(fd, cid, "sync has an invalid default printer", NULL, -1);
            return;
        }
        ovmc_memcpy(fallback, text, len);
        fallback[len] = '\0';
        if (!valid_printer_name(fallback)) {
            printer_reply(fd, cid, "sync has an invalid default printer", NULL, -1);
            return;
        }
    }
#ifdef OPENVM_REAL_WIN32
    static char joined[PRINTER_MAX * PRINTER_NAME_MAX];
    size_t j = 0;
    for (long i = 0; i < n; i++) {
        if (i)
            joined[j++] = ',';
        for (const char *p = wanted[i]; *p; p++)
            joined[j++] = *p;
    }
    joined[j] = '\0';
    int finished = 0;
    if (g_sync.thread != NULL) {
        if (WaitForSingleObject(g_sync.thread, 0) != WAIT_OBJECT_0) {
            printer_pending(fd, cid);
            return;
        }
        CloseHandle(g_sync.thread);
        g_sync.thread = NULL;
        finished = ovmc_strcmp(g_sync.names, joined) == 0; /* the host's list may have moved on */
    }
    if (!finished) {
        ovmc_memcpy(g_sync.names, joined, j + 1);
        g_sync.thread = CreateThread(NULL, 0, printer_sync_thread, NULL, 0, NULL);
        if (g_sync.thread == NULL) {
            printer_reply(fd, cid, "could not start the printer sync", NULL, -1);
            return;
        }
        printer_pending(fd, cid);
        return;
    }
    if (!g_sync.ok) {
        agent_log("printers.ps1 failed: %s", g_sync.why);
        printer_reply(fd, cid, g_sync.why[0] ? g_sync.why : "could not run printers.ps1", NULL, -1);
        return;
    }
    if (fallback[0]) {
        /* The default printer is per user. Nobody logged on yet is not an
         * error: the next change of default reaches them. */
        WCHAR mode[PRINTER_NAME_MAX + 24];
        swprintf(mode, sizeof mode / sizeof mode[0], L"--default-printer %hs", fallback);
        uint8_t reply[160];
        size_t got = 0;
        if (!run_in_user_session(mode, NULL, 0, reply, sizeof reply, &got))
            agent_log("default printer not set: %s",
                      g_helper_error ? g_helper_error : "helper failed");
    }
    agent_log("printers synced (%ld)", n);
    printer_reply(fd, cid, NULL, wanted, n);
#else
    printer_reply(fd, cid, "printing needs the real Win32 build", NULL, -1);
#endif
}

#ifdef OPENVM_REAL_WIN32
/* Finished jobs are moved aside under a name of their own. A rename that fails
 * means the spooler still holds the file: the job is running, try next poll. */
static void printer_claim_finished(void) {
    static unsigned serial;
    WIN32_FIND_DATAW e;
    HANDLE find = FindFirstFileW(WIN_SPOOL_DIR L"\\*.pdf", &e);
    if (find == INVALID_HANDLE_VALUE)
        return;
    do {
        char name[PRINTER_NAME_MAX + 8];
        size_t len = 0;
        int ascii = 1;
        for (const WCHAR *p = e.cFileName; *p; p++) {
            if (*p >= 0x80 || len + 1 >= sizeof name) {
                ascii = 0;
                break;
            }
            name[len++] = (char)*p;
        }
        name[len] = '\0';
        if (!ascii || len < 5 || ovmc_strstr(name, "--") != NULL ||
            e.nFileSizeLow + e.nFileSizeHigh == 0 ||
            (e.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)))
            continue;
        name[len - 4] = '\0';
        if (!valid_printer_name(name))
            continue;
        char job[PRINT_JOB_NAME_MAX];
        snprintf(job, sizeof job, "%s--%lu-%u.pdf", name, (unsigned long)GetTickCount(), ++serial);
        WCHAR from[WIN_PATH_MAX], to[WIN_PATH_MAX];
        name[len - 4] = '.';
        if (spool_path(name, from, WIN_PATH_MAX) && spool_path(job, to, WIN_PATH_MAX))
            MoveFileExW(from, to, 0);
    } while (FindNextFileW(find, &e));
    FindClose(find);
}
#endif

static void printer_jobs(SOCKET fd, uint64_t cid) {
    static struct ovmc_out w;
    ovmc_out_init(&w);
#ifdef OPENVM_REAL_WIN32
    struct entry {
        char job[PRINT_JOB_NAME_MAX];
        char printer[PRINTER_NAME_MAX];
        uint64_t size;
    };
    static struct entry found[PRINT_JOBS_MAX];
    size_t n = 0;
    printer_claim_finished();
    WIN32_FIND_DATAW e;
    HANDLE find = FindFirstFileW(WIN_SPOOL_DIR L"\\*--*.pdf", &e);
    if (find != INVALID_HANDLE_VALUE) {
        do {
            size_t len = 0;
            int ascii = 1;
            for (const WCHAR *p = e.cFileName; *p; p++) {
                if (*p >= 0x80 || len + 1 >= PRINT_JOB_NAME_MAX) {
                    ascii = 0;
                    break;
                }
                found[n].job[len++] = (char)*p;
            }
            found[n].job[len] = '\0';
            if (!ascii ||
                !safe_component((const uint8_t *)found[n].job, len, PRINT_JOB_NAME_MAX - 1, 0) ||
                (e.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)))
                continue;
            const char *split = NULL;
            for (const char *p = ovmc_strstr(found[n].job, "--"); p; p = ovmc_strstr(p + 1, "--"))
                split = p;
            size_t plen = split ? (size_t)(split - found[n].job) : 0;
            if (plen == 0 || plen >= PRINTER_NAME_MAX)
                continue;
            ovmc_memcpy(found[n].printer, found[n].job, plen);
            found[n].printer[plen] = '\0';
            found[n].size = ((uint64_t)e.nFileSizeHigh << 32) | e.nFileSizeLow;
            n++;
        } while (n < PRINT_JOBS_MAX && FindNextFileW(find, &e));
        FindClose(find);
    }
    ovmc_whdr(&w, 5, 2);
    ovmc_wtext(&w, "jobs");
    ovmc_whdr(&w, 4, n);
    for (size_t i = 0; i < n; i++) {
        ovmc_whdr(&w, 5, 3);
        ovmc_wtext(&w, "job");
        ovmc_wtext(&w, found[i].job);
        ovmc_wtext(&w, "printer");
        ovmc_wtext(&w, found[i].printer);
        ovmc_wtext(&w, "size");
        ovmc_wuint(&w, found[i].size);
    }
#else
    ovmc_whdr(&w, 5, 2);
    ovmc_wtext(&w, "jobs");
    ovmc_whdr(&w, 4, 0);
#endif
    ovmc_wtext(&w, "id");
    ovmc_wuint(&w, cid);
    if (w.ok)
        write_reply(fd, T_PRINTER_REPLY, w.b, w.n);
}

/* The spool file a `job` field names, or 0. Only a plain basename gets here,
 * and only a name the jobs op could have reported. */
static int printer_job_path(const uint8_t *body, const struct ovmc_pair *pairs, size_t count,
                            WCHAR *path, size_t cap) {
    const struct ovmc_pair *jp = ovmc_find(body, pairs, count, "job");
    const uint8_t *text = NULL;
    size_t len = 0;
    char job[PRINT_JOB_NAME_MAX];
    if (jp == NULL || !ovmc_text_span(body + jp->v0, jp->v1 - jp->v0, &text, &len) ||
        len >= PRINT_JOB_NAME_MAX || !safe_component(text, len, PRINT_JOB_NAME_MAX - 1, 0))
        return 0;
    ovmc_memcpy(job, text, len);
    job[len] = '\0';
    return ovmc_strstr(job, "--") != NULL && spool_path(job, path, cap);
}

static void printer_fetch(SOCKET fd, const uint8_t *body, const struct ovmc_pair *pairs,
                          size_t count, uint64_t cid) {
    WCHAR path[WIN_PATH_MAX];
    uint64_t offset = 0, length = 0;
    if (!printer_job_path(body, pairs, count, path, WIN_PATH_MAX) ||
        !decode_uint_pair(body, ovmc_find(body, pairs, count, "offset"), &offset) ||
        !decode_uint_pair(body, ovmc_find(body, pairs, count, "length"), &length) || length == 0 ||
        length > PRINT_CHUNK_MAX) {
        printer_reply(fd, cid, "fetch needs job, offset and a bounded length", NULL, -1);
        return;
    }
#ifdef OPENVM_REAL_WIN32
    HANDLE f = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                           FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (f == INVALID_HANDLE_VALUE) {
        printer_reply(fd, cid, "no such print job", NULL, -1);
        return;
    }
    static uint8_t chunk[PRINT_CHUNK_MAX];
    LARGE_INTEGER at;
    at.QuadPart = (LONGLONG)offset;
    DWORD got = 0;
    BOOL ok =
        SetFilePointerEx(f, at, NULL, FILE_BEGIN) && ReadFile(f, chunk, (DWORD)length, &got, NULL);
    CloseHandle(f);
    if (!ok || got == 0) {
        printer_reply(fd, cid, "print job read failed", NULL, -1);
        return;
    }
    static struct ovmc_out w;
    ovmc_out_init(&w);
    ovmc_whdr(&w, 5, 2);
    ovmc_wtext(&w, "data");
    ovmc_wbytes(&w, chunk, got);
    ovmc_wtext(&w, "id");
    ovmc_wuint(&w, cid);
    if (w.ok)
        write_reply(fd, T_PRINTER_REPLY, w.b, w.n);
#else
    printer_reply(fd, cid, "printing needs the real Win32 build", NULL, -1);
#endif
}

static void handle_printer(SOCKET fd, const uint8_t *body, const struct ovmc_pair *pairs,
                           size_t count, uint64_t cid) {
    const struct ovmc_pair *op = ovmc_find(body, pairs, count, "op");
    const uint8_t *optext = NULL;
    size_t oplen = 0;
    if (op == NULL || !ovmc_text_span(body + op->v0, op->v1 - op->v0, &optext, &oplen)) {
        printer_reply(fd, cid, "printer request has no usable op", NULL, -1);
        return;
    }

    if (oplen == 4 && ovmc_memcmp(optext, "list", 4) == 0) {
#ifdef OPENVM_REAL_WIN32
        /* A queue's port file is named after it, but an idle queue has no file:
         * the names live in the ports the spooler knows. */
        static char names[PRINTER_MAX][PRINTER_NAME_MAX];
        long n = 0;
        DWORD need = 0, returned = 0;
        EnumPrintersW(PRINTER_ENUM_LOCAL, NULL, 2, NULL, 0, &need, &returned);
        static uint8_t info[256 * 1024];
        if (need <= sizeof info &&
            EnumPrintersW(PRINTER_ENUM_LOCAL, NULL, 2, info, sizeof info, &need, &returned)) {
            const PRINTER_INFO_2W *p = (const PRINTER_INFO_2W *)info;
            for (DWORD i = 0; i < returned && n < PRINTER_MAX; i++) {
                static const WCHAR prefix[] = WIN_SPOOL_DIR L"\\";
                const WCHAR *port = p[i].pPortName;
                size_t k = 0;
                while (prefix[k] && port && port[k] == prefix[k])
                    k++;
                if (prefix[k] != 0)
                    continue;
                if (wide_to_utf8(p[i].pPrinterName, names[n], PRINTER_NAME_MAX) > 0)
                    n++;
            }
        }
        printer_reply(fd, cid, NULL, names, n);
#else
        printer_reply(fd, cid, NULL, NULL, 0);
#endif
        return;
    }
    if (oplen == 4 && ovmc_memcmp(optext, "sync", 4) == 0) {
        printer_sync(fd, body, pairs, count, cid);
        return;
    }
    if (oplen == 4 && ovmc_memcmp(optext, "jobs", 4) == 0) {
        printer_jobs(fd, cid);
        return;
    }
    if (oplen == 5 && ovmc_memcmp(optext, "fetch", 5) == 0) {
        printer_fetch(fd, body, pairs, count, cid);
        return;
    }
    if (oplen == 4 && ovmc_memcmp(optext, "done", 4) == 0) {
        WCHAR path[WIN_PATH_MAX];
        if (!printer_job_path(body, pairs, count, path, WIN_PATH_MAX)) {
            printer_reply(fd, cid, "done needs a job", NULL, -1);
            return;
        }
#ifdef OPENVM_REAL_WIN32
        if (!DeleteFileW(path) && GetLastError() != ERROR_FILE_NOT_FOUND) {
            printer_reply(fd, cid, "could not remove the print job", NULL, -1);
            return;
        }
#endif
        printer_reply(fd, cid, NULL, NULL, -1);
        return;
    }
    if (oplen == 4 && ovmc_memcmp(optext, "test", 4) == 0) {
        const struct ovmc_pair *np = ovmc_find(body, pairs, count, "name");
        const uint8_t *text = NULL;
        size_t len = 0;
        char name[PRINTER_NAME_MAX];
        if (np == NULL || !ovmc_text_span(body + np->v0, np->v1 - np->v0, &text, &len) ||
            len >= PRINTER_NAME_MAX) {
            printer_reply(fd, cid, "test needs a printer name", NULL, -1);
            return;
        }
        ovmc_memcpy(name, text, len);
        name[len] = '\0';
        if (!valid_printer_name(name)) {
            printer_reply(fd, cid, "test needs a printer name", NULL, -1);
            return;
        }
#ifdef OPENVM_REAL_WIN32
        /* As the logged-on user, which is how any application's job arrives. */
        WCHAR mode[PRINTER_NAME_MAX + 24];
        swprintf(mode, sizeof mode / sizeof mode[0], L"--print-test %hs", name);
        uint8_t reply[160];
        size_t got = 0;
        g_helper_error = NULL;
        if (!run_in_user_session(mode, NULL, 0, reply, sizeof reply, &got)) {
            printer_reply(fd, cid, g_helper_error ? g_helper_error : "the test page failed", NULL,
                          -1);
            return;
        }
#endif
        printer_reply(fd, cid, NULL, NULL, -1);
        return;
    }
    printer_reply(fd, cid, "printer op must be list, sync, jobs, fetch, done or test", NULL, -1);
}
