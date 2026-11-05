/* ---------- shared folders (14/15) ----------------------------------------
 * Shared folders ride virtio-fs: the host attaches one device (tag "openvm")
 * whose root holds one directory per share, keyed by share name. On Windows
 * the guest side is virtio-win's viofs driver plus its WinFsp-based VirtIO-FS
 * service, which mounts the tag as a drive (Z: by default). The agent records
 * name -> guest path and proves the round trip by reading the host's probe
 * file through Z:\<name>\. */
struct win_share {
    int used;
    char guest_path[256];
    char name[48];
};

#define WIN_SHARES_MAX 8
static struct win_share g_shares[WIN_SHARES_MAX];

static struct win_share *find_share(const char *guest_path) {
    for (int i = 0; i < WIN_SHARES_MAX; i++) {
        if (g_shares[i].used && ovmc_strcmp(g_shares[i].guest_path, guest_path) == 0)
            return &g_shares[i];
    }
    return NULL;
}

/* Absolute path, no traversal, no drive-relative form. Mirrors the Linux
 * agent's valid_guest_path so a share that is legal on one guest is legal on
 * the other. */
static int win_valid_guest_path(const char *s) {
    size_t n = ovmc_strlen(s);
    if (n == 0 || n > 255)
        return 0;
    /* Accept both "C:\openvm\share" and "/openvm/share": the host does not know
     * which form the guest prefers, and both are unambiguous. */
    size_t i = 0;
    if (n >= 2 && s[1] == ':')
        i = 2;
    if (s[i] != '\\' && s[i] != '/')
        return 0;
    for (; i < n; i++) {
        char c = s[i];
        if (c == '\\' || c == '/')
            continue;
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
            c == '.' || c == '_' || c == '-' || c == ' ')
            continue;
        return 0;
    }
    /* ".." anywhere is a traversal attempt. */
    if (ovmc_strstr(s, "..") != NULL)
        return 0;
    return 1;
}

/* A mount reply names where the share really is: on Windows every share is a
 * directory of the virtio-fs drive, whatever guest path the host asked for. */
static void shared_response_at(SOCKET fd, uint64_t cid, const char *error, const char *content,
                               const char *location) {
    struct ovmc_out w;
    ovmc_out_init(&w);
    ovmc_whdr(&w, 5, error ? 2 : 1 + (content ? 1 : 0) + (location ? 1 : 0));
    if (error) {
        ovmc_wtext(&w, "error");
        ovmc_wtext(&w, error);
    } else {
        if (content) {
            ovmc_wtext(&w, "content");
            ovmc_wtext(&w, content);
        }
        if (location) {
            ovmc_wtext(&w, "location");
            ovmc_wtext(&w, location);
        }
    }
    ovmc_wtext(&w, "id");
    ovmc_wuint(&w, cid);
    if (w.ok)
        write_reply(fd, T_SHARED_REPLY, w.b, w.n);
}

static void shared_response(SOCKET fd, uint64_t cid, const char *error, const char *content) {
    shared_response_at(fd, cid, error, content, NULL);
}

static void handle_shared(SOCKET fd, const uint8_t *body, const struct ovmc_pair *pairs,
                          size_t count, uint64_t cid) {
    const struct ovmc_pair *op_pair = ovmc_find(body, pairs, count, "op");
    const uint8_t *op = NULL;
    size_t op_len = 0;
    if (op_pair == NULL ||
        !ovmc_text_span(body + op_pair->v0, op_pair->v1 - op_pair->v0, &op, &op_len)) {
        shared_response(fd, cid, "shared request has no usable op", NULL);
        return;
    }

    int mounting = op_len == 5 && ovmc_memcmp(op, "mount", 5) == 0;
    int unmounting = op_len == 7 && ovmc_memcmp(op, "unmount", 7) == 0;

    const struct ovmc_pair *path_pair = ovmc_find(body, pairs, count, "path");
    const uint8_t *path = NULL;
    size_t path_len = 0;
    if (path_pair == NULL ||
        !ovmc_text_span(body + path_pair->v0, path_pair->v1 - path_pair->v0, &path, &path_len) ||
        path_len >= sizeof g_shares[0].guest_path) {
        shared_response(fd, cid, "shared request has no usable path", NULL);
        return;
    }
    char guest_path[256];
    ovmc_memcpy(guest_path, path, path_len);
    guest_path[path_len] = '\0';
    if (!win_valid_guest_path(guest_path)) {
        shared_response(fd, cid, "guest path must be absolute with no traversal", NULL);
        return;
    }

    if (unmounting) {
        struct win_share *s = find_share(guest_path);
        if (s == NULL) {
            shared_response(fd, cid, "no such share", NULL);
            return;
        }
        s->used = 0;
        shared_response(fd, cid, NULL, NULL);
        return;
    }

    if (!mounting) {
        shared_response(fd, cid, "shared op must be mount or unmount", NULL);
        return;
    }

    /* mount: the share's name inside the virtio-fs device ([a-z0-9]). */
    const struct ovmc_pair *name_pair = ovmc_find(body, pairs, count, "name");
    const uint8_t *share_name = NULL;
    size_t name_len = 0;
    if (name_pair == NULL ||
        !ovmc_text_span(body + name_pair->v0, name_pair->v1 - name_pair->v0, &share_name,
                        &name_len) ||
        name_len == 0 || name_len >= sizeof g_shares[0].name) {
        shared_response(fd, cid, "shared request has no usable share name", NULL);
        return;
    }
    for (size_t i = 0; i < name_len; i++) {
        uint8_t c = share_name[i];
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'))) {
            shared_response(fd, cid, "shared request has no usable share name", NULL);
            return;
        }
    }

    struct win_share *slot = find_share(guest_path);
    if (slot == NULL) {
        for (int i = 0; i < WIN_SHARES_MAX; i++) {
            if (!g_shares[i].used) {
                slot = &g_shares[i];
                break;
            }
        }
    }
    if (slot == NULL) {
        shared_response(fd, cid, "share table is full", NULL);
        return;
    }

    ovmc_memcpy(slot->guest_path, guest_path, path_len);
    slot->guest_path[path_len] = '\0';
    ovmc_memcpy(slot->name, share_name, name_len);
    slot->name[name_len] = '\0';
    slot->used = 1;

    char location[48];
    size_t ln = 0;
    location[ln++] = (char)WIN_VIRTIOFS_LETTER;
    location[ln++] = ':';
    location[ln++] = '\\';
    for (size_t i = 0; i < name_len && ln < sizeof location - 1; i++)
        location[ln++] = (char)share_name[i];
    location[ln] = '\0';

    /* The probe file the host wrote into the shared directory, read back
     * through the virtio-fs drive: the proof that the share really works. */
    const struct ovmc_pair *probe_pair = ovmc_find(body, pairs, count, "probe");
    const uint8_t *probe = NULL;
    size_t probe_len = 0;
    if (probe_pair != NULL &&
        ovmc_text_span(body + probe_pair->v0, probe_pair->v1 - probe_pair->v0, &probe,
                       &probe_len) &&
        probe_len > 0 && probe_len < 240) {
        char probe_name[241];
        ovmc_memcpy(probe_name, probe, probe_len);
        probe_name[probe_len] = '\0';
        if (!safe_component((const uint8_t *)probe_name, probe_len, 240, 0)) {
            shared_response(fd, cid, "probe name must be a plain basename", NULL);
            return;
        }
        char content[512];
        if (share_read_probe(slot->name, probe_name, content, sizeof content) == 0) {
            shared_response(fd, cid, "probe file not readable through the share", NULL);
            return;
        }
        shared_response_at(fd, cid, NULL, content, location);
        return;
    }

    shared_response_at(fd, cid, NULL, NULL, location);
}
