/* ---------- drag and drop (18/19) ----------------------------------------
 * The host announces a drag as the pointer enters the guest window, carries the
 * payload on drop, and cancels on leave. The guest decides whether it can
 * accept; the host never assumes.
 *
 * On Linux the drop target is the desktop session: a real implementation
 * speaks XDND (X11) or the wl_data_device protocol (Wayland). The agent has no
 * session of its own, so it validates the announcement and reports acceptance
 * without claiming the files reached the file manager. */
static void drag_response(int fd, uint64_t cid, int accepted, const char *error) {
    struct ovmc_out w;
    w.n = 0;
    w.ok = 1;
    ovmc_whdr(&w, 5, error ? 3 : 2);
    ovmc_whdr(&w, 0, 0); /* placeholder replaced below */
    w.n = 0;
    w.ok = 1;
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

/* ---------- files dragged into the guest (18/19) ---------------------------
 * The host stages the items as a read-only share (DragControl.swift)
 * and the agent copies them to the session user's Desktop. The copy is a child,
 * so a large tree does not hold the channel, and it runs as that user: the
 * Desktop is theirs, and root following a link they planted there would write
 * anywhere. Results come back through an unlinked file, one line per item. */
#ifndef OPENVM_RUN_USER
#define OPENVM_RUN_USER "/run/user"
#endif
#define DROP_ITEMS_MAX 64
#define DROP_NAME_MAX 256

static struct {
    pid_t pid;
    int results;
} g_drop;

/* Unicode and spaces are ordinary; what is refused could leave the folder or
 * break the one-name-per-line results. */
static int valid_drop_item(const char *s) {
    size_t n = strlen(s);
    if (n == 0 || n >= DROP_NAME_MAX || strcmp(s, ".") == 0 || strcmp(s, "..") == 0)
        return 0;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c == '/' || c < 0x20 || c == 0x7f)
            return 0;
    }
    return 1;
}

/* The logged-in desktop user: the one who published a session file. */
static int drop_session_user(uid_t *uid) {
    DIR *dir = opendir(OPENVM_RUN_USER);
    if (dir == NULL)
        return 0;
    struct dirent *e;
    int found = 0;
    while (!found && (e = readdir(dir)) != NULL) {
        char path[320];
        char *end = NULL;
        unsigned long id = strtoul(e->d_name, &end, 10);
        if (e->d_name[0] == '.' || *end != '\0')
            continue;
        snprintf(path, sizeof path, "%s/%s/openvm-clipboard.env", OPENVM_RUN_USER, e->d_name);
        if (access(path, R_OK) == 0) {
            *uid = (uid_t)id;
            found = 1;
        }
    }
    closedir(dir);
    return found;
}

static uint64_t g_tree_bytes;

static int tree_bytes_visit(const char *path, const struct stat *st, int type, struct FTW *ftw) {
    (void)path;
    (void)ftw;
    if (type == FTW_F && S_ISREG(st->st_mode))
        g_tree_bytes += (uint64_t)st->st_size;
    return 0;
}

/* "name.txt" -> "name (2).txt", the way a file manager would. */
static int drop_unique_path(const char *folder, const char *item, char *out, size_t cap) {
    struct stat st;
    if ((size_t)snprintf(out, cap, "%s/%s", folder, item) >= cap)
        return 0;
    const char *dot = strrchr(item, '.');
    size_t stem = dot && dot != item ? (size_t)(dot - item) : strlen(item);
    for (int n = 2; lstat(out, &st) == 0; n++) {
        if (n > 999 || (size_t)snprintf(out, cap, "%s/%.*s (%d)%s", folder, (int)stem, item, n,
                                        item + stem) >= cap)
            return 0;
    }
    return 1;
}

/* Never returns. Runs in the forked child. */
static void drop_copy(const char *share, char items[][DROP_NAME_MAX], long count, uid_t uid,
                      int results) {
    for (int fd = 3; fd < 256; fd++)
        if (fd != results)
            close(fd);
    struct passwd *pw = getpwuid(uid);
    if (pw == NULL) {
        dprintf(results, "err the session user has no account\n");
        _exit(1);
    }
#ifdef OPENVM_DROP_HOME
    const char *home_dir = OPENVM_DROP_HOME;
#else
    const char *home_dir = pw->pw_dir;
#endif
    if (getuid() != uid &&
        (initgroups(pw->pw_name, pw->pw_gid) != 0 || setgid(pw->pw_gid) != 0 || setuid(uid) != 0)) {
        dprintf(results, "err could not become the session user\n");
        _exit(1);
    }
    char desktop[320];
    snprintf(desktop, sizeof desktop, "%s/Desktop", home_dir);
    if (mkdir(desktop, 0755) != 0 && errno != EEXIST) {
        dprintf(results, "err could not create the Desktop folder\n");
        _exit(1);
    }
    for (long i = 0; i < count; i++) {
        char src[640], final[640], tmp[400];
        struct stat st;
        snprintf(src, sizeof src, "%s/drops/%s/%s", OPENVM_FS_ROOT, share, items[i]);
        snprintf(tmp, sizeof tmp, "%s/.openvm-drop-%d", desktop, (int)getpid());
        if (lstat(src, &st) != 0 || !drop_unique_path(desktop, items[i], final, sizeof final)) {
            dprintf(results, "err could not place %s\n", items[i]);
            _exit(1);
        }
        pid_t cp = fork();
        if (cp == 0) {
            execlp("cp", "cp", "-RP", "--", src, tmp, (char *)NULL);
            _exit(127);
        }
        int status = 1;
        if (cp < 0 || waitpid(cp, &status, 0) < 0 || !WIFEXITED(status) ||
            WEXITSTATUS(status) != 0 || rename(tmp, final) != 0) {
            /* Never leave half a copy on the user's Desktop. */
            pid_t rm = fork();
            if (rm == 0) {
                execlp("rm", "rm", "-rf", "--", tmp, (char *)NULL);
                _exit(127);
            }
            if (rm > 0)
                waitpid(rm, NULL, 0);
            dprintf(results, "err could not copy %s\n", items[i]);
            _exit(1);
        }
        g_tree_bytes = 0;
        nftw(final, tree_bytes_visit, 16, FTW_PHYS);
        dprintf(results, "ok %llu %s\n", (unsigned long long)g_tree_bytes, strrchr(final, '/') + 1);
    }
    _exit(0);
}

/* `items`: a definite array of valid names. -1 on anything else. */
static long drop_item_array(const uint8_t *p, size_t span, char out[][DROP_NAME_MAX], size_t cap) {
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
    if (count == 0 || count > cap)
        return -1;
    struct ovmc_cur c = {p, span, head, 1};
    for (size_t i = 0; i < count; i++) {
        size_t start = c.i;
        ovmc_parse_val(&c);
        const uint8_t *text = NULL;
        size_t len = 0;
        if (!c.ok || !ovmc_text_span(p + start, c.i - start, &text, &len) || len >= DROP_NAME_MAX)
            return -1;
        memcpy(out[i], text, len);
        out[i][len] = '\0';
        if (strlen(out[i]) != len || !valid_drop_item(out[i]))
            return -1;
    }
    return c.i == span ? (long)count : -1;
}

/* Makes the share visible under OPENVM_FS_ROOT. It joined the device after the
 * tag was mounted, so cached lookups have to go first. */
static int drop_mount_share(const char *share) {
#ifdef OPENVM_DROP_NO_MOUNT
    (void)share;
    return 1;
#else
    char cmd[512];
    snprintf(cmd, sizeof cmd,
             "modprobe virtiofs 2>/dev/null; sync; echo 2 > /proc/sys/vm/drop_caches 2>/dev/null; "
             "mkdir -p " OPENVM_FS_ROOT " && "
             "{ grep -q ' " OPENVM_FS_ROOT " ' /proc/mounts || "
             "mount -t virtiofs " OPENVM_FS_TAG " " OPENVM_FS_ROOT "; } >/dev/null 2>&1; "
             "[ -d '" OPENVM_FS_ROOT "/drops/%s' ]",
             share);
    return system(cmd) == 0;
#endif
}

static void drag_start(int fd, const uint8_t *body, const struct ovmc_pair *pairs, size_t count,
                       uint64_t cid) {
    static char items[DROP_ITEMS_MAX][DROP_NAME_MAX];
    char share[48];
    uid_t uid = 0;
    if (g_drop.pid != 0) {
        drag_response(fd, cid, 0, "a drop is already running");
        return;
    }
    const struct ovmc_pair *list = find_pair(body, pairs, count, "items");
    long n =
        list ? drop_item_array(body + list->v0, list->v1 - list->v0, items, DROP_ITEMS_MAX) : -1;
    if (n < 0) {
        drag_response(fd, cid, 0, "drop needs a list of valid item names");
        return;
    }
    if (!text_field(body, pairs, count, "share", share, sizeof share) || !valid_share_name(share)) {
        drag_response(fd, cid, 0, "drop has no usable share");
        return;
    }
    if (!drop_session_user(&uid)) {
        drag_response(fd, cid, 0, "no user is logged on to the guest desktop");
        return;
    }
    if (!drop_mount_share(share)) {
        drag_response(fd, cid, 0, "this guest was started without the drops share; restart it");
        return;
    }
    FILE *results = tmpfile();
    if (results == NULL) {
        drag_response(fd, cid, 0, "could not record the drop");
        return;
    }
    int results_fd = dup(fileno(results));
    fclose(results);
    pid_t pid = fork();
    if (pid == 0)
        drop_copy(share, items, n, uid, results_fd);
    if (pid < 0) {
        close(results_fd);
        drag_response(fd, cid, 0, "could not start the copy");
        return;
    }
    g_drop.pid = pid;
    g_drop.results = results_fd;
    fprintf(stderr, "openvm-tools: drop of %ld item(s) started\n", n);
    drag_response(fd, cid, 1, NULL);
}

static void drag_status(int fd, uint64_t cid) {
    struct ovmc_out *w = malloc(sizeof *w);
    if (w == NULL)
        return;
    w->n = 0;
    w->ok = 1;
    int status = 0;
    if (g_drop.pid == 0) {
        free(w);
        drag_response(fd, cid, 0, "no drop is running");
        return;
    }
    if (waitpid(g_drop.pid, &status, WNOHANG) == 0) {
        ovmc_whdr(w, 5, 3);
        ovmc_wtext(w, "accepted");
        ovmc_wbool(w, 1);
        ovmc_wtext(w, "done");
        ovmc_wbool(w, 0);
    } else {
        static char text[DROP_ITEMS_MAX * (DROP_NAME_MAX + 32)];
        ssize_t got = pread(g_drop.results, text, sizeof text - 1, 0);
        text[got > 0 ? got : 0] = '\0';
        close(g_drop.results);
        g_drop.pid = 0;
        const char *error = NULL;
        const char *placed[DROP_ITEMS_MAX];
        size_t n = 0;
        uint64_t bytes = 0;
        for (char *line = strtok(text, "\n"); line != NULL; line = strtok(NULL, "\n")) {
            char *rest = NULL;
            if (strncmp(line, "ok ", 3) == 0 && n < DROP_ITEMS_MAX) {
                bytes += strtoull(line + 3, &rest, 10);
                placed[n++] = rest + 1;
            } else if (strncmp(line, "err ", 4) == 0) {
                error = line + 4;
            }
        }
        if (error == NULL && (!WIFEXITED(status) || WEXITSTATUS(status) != 0))
            error = "the copy stopped early";
        ovmc_whdr(w, 5, error ? 6 : 5);
        ovmc_wtext(w, "accepted");
        ovmc_wbool(w, 1);
        ovmc_wtext(w, "done");
        ovmc_wbool(w, 1);
        ovmc_wtext(w, "placed");
        ovmc_whdr(w, 4, n);
        for (size_t i = 0; i < n; i++)
            ovmc_wtext(w, placed[i]);
        ovmc_wtext(w, "bytes");
        ovmc_wuint(w, bytes);
        if (error) {
            ovmc_wtext(w, "error");
            ovmc_wtext(w, error);
        }
        fprintf(stderr, "openvm-tools: drop finished, %zu item(s)\n", n);
    }
    ovmc_wtext(w, "id");
    ovmc_wuint(w, cid);
    if (w->ok)
        write_reply(fd, T_DRAG_REPLY, w->b, w->n);
    free(w);
}

/* Runs the send tool as the desktop user on one guest path, and waits. This is what the file
 * manager's "Send to Mac" action does, made reachable from the host so a smoke test (and
 * `openvmctl drag send`) can exercise it. The path is held to the same strict charset as every
 * other guest path the host names. */
#ifndef OPENVM_SEND_BIN
#define OPENVM_SEND_BIN "/usr/local/bin/openvm-send"
#endif
static void drag_send(int fd, const uint8_t *body, const struct ovmc_pair *pairs, size_t count,
                      uint64_t cid) {
    char path[256];
    uid_t uid = 0;
    if (!text_field(body, pairs, count, "path", path, sizeof path) || !valid_guest_path(path)) {
        drag_response(fd, cid, 0, "send has no usable path");
        return;
    }
    if (!drop_session_user(&uid)) {
        drag_response(fd, cid, 0, "no user is logged on to the guest desktop");
        return;
    }
    pid_t pid = fork();
    if (pid < 0) {
        drag_response(fd, cid, 0, "could not start the send");
        return;
    }
    if (pid == 0) {
        for (int c = 3; c < 256; c++)
            close(c);
        struct passwd *pw = getpwuid(uid);
        if (pw == NULL || (getuid() != uid && (initgroups(pw->pw_name, pw->pw_gid) != 0 ||
                                               setgid(pw->pw_gid) != 0 || setuid(uid) != 0)))
            _exit(126);
        execl(OPENVM_SEND_BIN, OPENVM_SEND_BIN, path, (char *)NULL);
        _exit(127);
    }
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
    }
    int ok = WIFEXITED(status) && WEXITSTATUS(status) == 0;
    drag_response(fd, cid, ok, ok ? NULL : "the send tool refused or failed");
}

static void handle_drag(int fd, const uint8_t *body, const struct ovmc_pair *pairs, size_t count,
                        uint64_t cid) {
    char op[16];
    if (!text_field(body, pairs, count, "op", op, sizeof op)) {
        drag_response(fd, cid, 0, "drag request has no usable op");
        return;
    }
    if (strcmp(op, "enter") == 0) {
        uid_t uid;
        int ready = drop_session_user(&uid);
        drag_response(fd, cid, ready, ready ? NULL : "no user is logged on to the guest desktop");
    } else if (strcmp(op, "leave") == 0) {
        drag_response(fd, cid, 1, NULL);
    } else if (strcmp(op, "drop") == 0) {
        drag_start(fd, body, pairs, count, cid);
    } else if (strcmp(op, "status") == 0) {
        drag_status(fd, cid);
    } else if (strcmp(op, "send") == 0) {
        drag_send(fd, body, pairs, count, cid);
    } else {
        drag_response(fd, cid, 0, "drag op must be enter, leave, drop, status or send");
    }
}
