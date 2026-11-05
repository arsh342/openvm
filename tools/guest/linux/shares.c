/* ---------- shared folders: mount a host export over 9p ------------------
 * Virtualization.framework has no virtio-9p device, so the host runs a 9p
 * server and the guest mounts it with 9pnet over TCP. The host owns the
 * export set; the guest only mounts what the daemon asks for. Every field is
 * validated before it reaches a shell (host = dotted quad, token = hex, path
 * = strict absolute path), and the agent runs as root under its OpenRC
 * service, so mount/umount are available. */
static void shared_response(int fd, uint64_t cid, const char *error, const char *content) {
    struct ovmc_out *w = malloc(sizeof *w); /* heap: 1 MiB stack frames crash worker threads */
    if (!w)
        return;
    w->n = 0;
    w->ok = 1;
    ovmc_whdr(w, 5, error ? 2 : (content ? 2 : 1));
    if (error) {
        ovmc_wtext(w, "error");
        ovmc_wtext(w, error);
    } else if (content) {
        ovmc_wtext(w, "content");
        ovmc_wtext(w, content);
    }
    ovmc_wtext(w, "id");
    ovmc_wuint(w, cid);
    if (w->ok)
        write_reply(fd, T_SHARED_REPLY, w->b, w->n);
    free(w);
}

static int text_field(const uint8_t *body, const struct ovmc_pair *pairs, size_t count,
                      const char *key, char *out, size_t cap) {
    const struct ovmc_pair *p = find_pair(body, pairs, count, key);
    if (!p)
        return 0;
    const uint8_t *t = NULL;
    size_t tlen = 0;
    if (!ovmc_text_span(body + p->v0, p->v1 - p->v0, &t, &tlen))
        return 0;
    if (tlen == 0 || tlen >= cap)
        return 0;
    memcpy(out, t, tlen);
    out[tlen] = '\0';
    return 1;
}

/* A share name inside the virtio-fs device: the host derives it from the host
 * path ("s" + 16 lowercase hex), so anything else is refused. */
static int valid_share_name(const char *s) {
    size_t n = strlen(s);
    if (n == 0 || n > 40)
        return 0;
    for (size_t i = 0; i < n; i++)
        if (!((s[i] >= 'a' && s[i] <= 'z') || (s[i] >= '0' && s[i] <= '9')))
            return 0;
    return 1;
}

static int valid_guest_path(const char *s) { /* absolute, no "..", strict charset */
    size_t n = strlen(s);
    if (n == 0 || n > 240 || s[0] != '/')
        return 0;
    size_t i = 1;
    while (i < n) {
        size_t start = i;
        while (i < n && s[i] != '/')
            i++;
        size_t len = i - start;
        if (len == 0)
            return 0; /* "//" */
        if (len == 2 && s[start] == '.' && s[start + 1] == '.')
            return 0;
        for (size_t j = start; j < i; j++) {
            char c = s[j];
            if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
                  c == '_' || c == '-' || c == '.'))
                return 0;
        }
        if (i == n)
            return 1;
        i++; /* skip '/' */
        if (i == n)
            return 0; /* trailing slash */
    }
    return 1;
}

static int valid_probe_name(const char *s) { /* basename, no separators */
    size_t n = strlen(s);
    if (n == 0 || n > 240)
        return 0;
    if ((n == 1 && s[0] == '.') || (n == 2 && s[0] == '.' && s[1] == '.'))
        return 0;
    for (size_t i = 0; i < n; i++) {
        char c = s[i];
        if (c == '/')
            return 0;
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
              c == '_' || c == '-' || c == '.'))
            return 0;
    }
    return 1;
}

static void trim_eol(char *s) {
    size_t n = strlen(s);
    while (n > 0 && (s[n - 1] == '\n' || s[n - 1] == '\r'))
        s[--n] = '\0';
}

/* Decisive facts about the guest's 9p client: whether the filesystem type is
 * registered, which 9p modules the kernel actually ships, the last kernel
 * messages, and how a mount with an unknown or alternative transport behaves.
 * An unknown transport that fails instantly means the option parser is
 * reached; one that hangs means the kernel is waiting on a module autoload. */
