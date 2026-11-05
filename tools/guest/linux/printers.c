/* ---------- printers (20/21) ---------------------------------------------
 * The host publishes its printers (sync); each becomes a CUPS queue
 * that renders to PDF and whose backend (tools/guest/openvm-print-backend)
 * leaves the finished job in the spool. The host collects from there (jobs,
 * fetch, done): it is the only opener of the channel, so nothing is pushed. */
#ifndef OPENVM_PRINT_SPOOL
#define OPENVM_PRINT_SPOOL "/var/spool/openvm-print"
#endif
#ifndef OPENVM_PRINT_PPD
#define OPENVM_PRINT_PPD "/opt/openvm/openvm-pdf.ppd"
#endif
#define PRINTER_MAX 32
#define PRINTER_NAME_MAX 97
#define PRINT_JOBS_MAX 16
#define PRINT_CHUNK_MAX (64 * 1024)

/* The same alphabet the host checks: names reach a shell below. */
static int valid_printer_name(const char *s) {
    size_t n = strlen(s);
    if (n == 0 || n >= PRINTER_NAME_MAX || s[0] == '.' || s[0] == '-')
        return 0;
    for (size_t i = 0; i < n; i++) {
        char c = s[i];
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
              c == '.' || c == '_' || c == '-'))
            return 0;
    }
    return 1;
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
        memcpy(out[i], text, len);
        out[i][len] = '\0';
        if (!valid_printer_name(out[i]))
            return -1;
    }
    return c.i == span ? (long)count : -1;
}

/* The queues this agent owns: those whose device is our backend. */
static size_t own_queues(char out[][PRINTER_NAME_MAX], size_t cap) {
    size_t count = 0;
    FILE *pipe = popen("LC_ALL=C lpstat -v 2>/dev/null", "r");
    if (pipe == NULL)
        return 0;
    char line[320];
    while (fgets(line, sizeof line, pipe) != NULL) {
        static const char prefix[] = "device for ";
        char *end = strstr(line, ": openvm:/");
        if (strncmp(line, prefix, sizeof prefix - 1) != 0 || end == NULL || count >= cap)
            continue;
        *end = '\0';
        const char *name = line + sizeof prefix - 1;
        if (valid_printer_name(name))
            snprintf(out[count++], PRINTER_NAME_MAX, "%s", name);
    }
    pclose(pipe);
    return count;
}

/* Runs a CUPS tool. What it says is the only explanation there will be, so it
 * goes to the console and into g_printer_said for the reply. */
static char g_printer_said[200];

static int printer_shell(const char *fmt, const char *a, const char *b) {
    char cmd[512];
    if (snprintf(cmd, sizeof cmd, fmt, a, b) >= (int)sizeof cmd)
        return 0;
    FILE *pipe = popen(cmd, "r");
    if (pipe == NULL)
        return 0;
    size_t got = fread(g_printer_said, 1, sizeof g_printer_said - 1, pipe);
    g_printer_said[got] = '\0';
    trim_eol(g_printer_said);
    int status = pclose(pipe);
    if (status != 0)
        fprintf(stderr, "openvm-tools: `%s` failed (%d): %s\n", cmd, status, g_printer_said);
    return status == 0;
}

static void printer_reply(int fd, uint64_t cid, const char *error, char names[][PRINTER_NAME_MAX],
                          long count) {
    struct ovmc_out *w = malloc(sizeof *w);
    if (!w)
        return;
    w->n = 0;
    w->ok = 1;
    ovmc_whdr(w, 5, (error || count >= 0) ? 2 : 1);
    if (error) {
        ovmc_wtext(w, "error");
        ovmc_wtext(w, error);
    } else if (count >= 0) {
        ovmc_wtext(w, "printers");
        ovmc_whdr(w, 4, (uint64_t)count);
        for (long i = 0; i < count; i++)
            ovmc_wtext(w, names[i]);
    }
    ovmc_wtext(w, "id");
    ovmc_wuint(w, cid);
    if (w->ok)
        write_reply(fd, T_PRINTER_REPLY, w->b, w->n);
    free(w);
}

static void printer_sync(int fd, const uint8_t *body, const struct ovmc_pair *pairs, size_t count,
                         uint64_t cid) {
    char wanted[PRINTER_MAX][PRINTER_NAME_MAX];
    char have[PRINTER_MAX][PRINTER_NAME_MAX];
    const struct ovmc_pair *list = find_pair(body, pairs, count, "printers");
    long n =
        list ? printer_name_array(body + list->v0, list->v1 - list->v0, wanted, PRINTER_MAX) : -1;
    if (n < 0) {
        printer_reply(fd, cid, "sync needs a list of valid printer names", NULL, -1);
        return;
    }
    char fallback[PRINTER_NAME_MAX] = "";
    if (find_pair(body, pairs, count, "default") != NULL &&
        (!text_field(body, pairs, count, "default", fallback, sizeof fallback) ||
         !valid_printer_name(fallback))) {
        printer_reply(fd, cid, "sync has an invalid default printer", NULL, -1);
        return;
    }
    /* A guest without CUPS is fine until there is something to print to. */
    int probe = system("command -v lpadmin >/dev/null 2>&1");
    if (probe != 0) {
        fprintf(stderr, "openvm-tools: no lpadmin (status %d, PATH=%s)\n", probe, getenv("PATH"));
        printer_reply(fd, cid, n ? "CUPS is not installed in this guest" : NULL, NULL, n ? -1 : 0);
        return;
    }
    size_t held = own_queues(have, PRINTER_MAX);
    for (size_t i = 0; i < held; i++) {
        int keep = 0;
        for (long j = 0; j < n; j++)
            keep |= strcmp(have[i], wanted[j]) == 0;
        if (!keep)
            (void)printer_shell("lpadmin -x %s 2>&1", have[i], NULL);
    }
    for (long j = 0; j < n; j++) {
        /* Our PPD ends the filter chain at PDF; openvm:/ is the backend. */
        if (!printer_shell("lpadmin -p %s -E -v openvm:/%s -P " OPENVM_PRINT_PPD " 2>&1", wanted[j],
                           wanted[j])) {
            printer_reply(fd, cid,
                          g_printer_said[0] ? g_printer_said : "lpadmin could not create a queue",
                          NULL, -1);
            return;
        }
    }
    if (fallback[0] && !printer_shell("lpadmin -d %s 2>&1", fallback, NULL))
        fprintf(stderr, "openvm-tools: could not set default printer %s\n", fallback);
    fprintf(stderr, "openvm-tools: printers synced (%ld)\n", n);
    printer_reply(fd, cid, NULL, wanted, n);
}

/* Spool entries are PRINTER--JOB.pdf, written by the backend with a rename, so
 * a name ending in .pdf is complete. */
static void printer_jobs(int fd, uint64_t cid) {
    struct entry {
        char job[256];
        char printer[PRINTER_NAME_MAX];
        uint64_t size;
    };
    struct entry found[PRINT_JOBS_MAX];
    size_t n = 0;
    DIR *dir = opendir(OPENVM_PRINT_SPOOL);
    if (dir != NULL) {
        struct dirent *e;
        while (n < PRINT_JOBS_MAX && (e = readdir(dir)) != NULL) {
            size_t len = strlen(e->d_name);
            struct stat st;
            char path[sizeof OPENVM_PRINT_SPOOL + 260];
            if (len < 5 || len >= sizeof found[0].job || e->d_name[0] == '.' ||
                strcmp(e->d_name + len - 4, ".pdf") != 0 ||
                !safe_component((const uint8_t *)e->d_name, len, 255, 0))
                continue;
            snprintf(path, sizeof path, "%s/%s", OPENVM_PRINT_SPOOL, e->d_name);
            if (lstat(path, &st) != 0 || !S_ISREG(st.st_mode))
                continue;
            const char *split = NULL;
            for (const char *p = strstr(e->d_name, "--"); p != NULL; p = strstr(p + 1, "--"))
                split = p;
            if (split == NULL || (size_t)(split - e->d_name) >= PRINTER_NAME_MAX)
                continue;
            memcpy(found[n].printer, e->d_name, (size_t)(split - e->d_name));
            found[n].printer[split - e->d_name] = '\0';
            memcpy(found[n].job, e->d_name, len + 1);
            found[n].size = (uint64_t)st.st_size;
            n++;
        }
        closedir(dir);
    }
    struct ovmc_out *w = malloc(sizeof *w);
    if (!w)
        return;
    w->n = 0;
    w->ok = 1;
    ovmc_whdr(w, 5, 2);
    ovmc_wtext(w, "jobs");
    ovmc_whdr(w, 4, n);
    for (size_t i = 0; i < n; i++) {
        ovmc_whdr(w, 5, 3);
        ovmc_wtext(w, "job");
        ovmc_wtext(w, found[i].job);
        ovmc_wtext(w, "printer");
        ovmc_wtext(w, found[i].printer);
        ovmc_wtext(w, "size");
        ovmc_wuint(w, found[i].size);
    }
    ovmc_wtext(w, "id");
    ovmc_wuint(w, cid);
    if (w->ok)
        write_reply(fd, T_PRINTER_REPLY, w->b, w->n);
    free(w);
}

/* The spool file a `job` field names, or 0. Only a plain basename gets here. */
static int printer_job_path(const uint8_t *body, const struct ovmc_pair *pairs, size_t count,
                            char *path, size_t cap) {
    char job[256];
    if (!text_field(body, pairs, count, "job", job, sizeof job) ||
        !safe_component((const uint8_t *)job, strlen(job), 255, 0))
        return 0;
    return snprintf(path, cap, "%s/%s", OPENVM_PRINT_SPOOL, job) < (int)cap;
}

static void printer_fetch(int fd, const uint8_t *body, const struct ovmc_pair *pairs, size_t count,
                          uint64_t cid) {
    char path[sizeof OPENVM_PRINT_SPOOL + 260];
    uint64_t offset = 0, length = 0;
    if (!printer_job_path(body, pairs, count, path, sizeof path) ||
        !decode_uint_pair(body, find_pair(body, pairs, count, "offset"), &offset) ||
        !decode_uint_pair(body, find_pair(body, pairs, count, "length"), &length) || length == 0 ||
        length > PRINT_CHUNK_MAX) {
        printer_reply(fd, cid, "fetch needs job, offset and a bounded length", NULL, -1);
        return;
    }
    int file = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (file < 0) {
        printer_reply(fd, cid, "no such print job", NULL, -1);
        return;
    }
    /* Heap: worker threads have small stacks on musl. */
    uint8_t *chunk = malloc(PRINT_CHUNK_MAX);
    struct ovmc_out *w = malloc(sizeof *w);
    ssize_t got = chunk ? pread(file, chunk, (size_t)length, (off_t)offset) : -1;
    close(file);
    if (got <= 0 || !w) {
        printer_reply(fd, cid, "print job read failed", NULL, -1);
        free(chunk);
        free(w);
        return;
    }
    w->n = 0;
    w->ok = 1;
    ovmc_whdr(w, 5, 2);
    ovmc_wtext(w, "data");
    ovmc_wbytes(w, chunk, (size_t)got);
    ovmc_wtext(w, "id");
    ovmc_wuint(w, cid);
    if (w->ok)
        write_reply(fd, T_PRINTER_REPLY, w->b, w->n);
    free(chunk);
    free(w);
}

/* A page through the real queue, the way any application prints: the proof
 * that the whole path works, for the user and for the end-to-end test. */
static void printer_test(int fd, const uint8_t *body, const struct ovmc_pair *pairs, size_t count,
                         uint64_t cid) {
    char name[PRINTER_NAME_MAX];
    if (!text_field(body, pairs, count, "name", name, sizeof name) || !valid_printer_name(name)) {
        printer_reply(fd, cid, "test needs a printer name", NULL, -1);
        return;
    }
    if (!printer_shell("echo 'openVM test page from a Linux guest (%s)' | lp -d %s 2>&1", name,
                       name)) {
        printer_reply(fd, cid, "lp refused the test page", NULL, -1);
        return;
    }
    printer_reply(fd, cid, NULL, NULL, -1);
}

static void handle_printer(int fd, const uint8_t *body, const struct ovmc_pair *pairs, size_t count,
                           uint64_t cid) {
    char op[16];
    if (!text_field(body, pairs, count, "op", op, sizeof op)) {
        printer_reply(fd, cid, "printer request has no usable op", NULL, -1);
        return;
    }
    if (strcmp(op, "list") == 0) {
        char names[PRINTER_MAX][PRINTER_NAME_MAX];
        printer_reply(fd, cid, NULL, names, (long)own_queues(names, PRINTER_MAX));
    } else if (strcmp(op, "sync") == 0) {
        printer_sync(fd, body, pairs, count, cid);
    } else if (strcmp(op, "jobs") == 0) {
        printer_jobs(fd, cid);
    } else if (strcmp(op, "fetch") == 0) {
        printer_fetch(fd, body, pairs, count, cid);
    } else if (strcmp(op, "done") == 0) {
        char path[sizeof OPENVM_PRINT_SPOOL + 260];
        if (!printer_job_path(body, pairs, count, path, sizeof path))
            printer_reply(fd, cid, "done needs a job", NULL, -1);
        else if (unlink(path) != 0 && errno != ENOENT)
            printer_reply(fd, cid, "could not remove the print job", NULL, -1);
        else
            printer_reply(fd, cid, NULL, NULL, -1);
    } else if (strcmp(op, "test") == 0) {
        printer_test(fd, body, pairs, count, cid);
    } else {
        printer_reply(fd, cid, "printer op must be list, sync, jobs, fetch, done or test", NULL,
                      -1);
    }
}
