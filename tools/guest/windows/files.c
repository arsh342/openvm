/* ---------- file service (message types 10 and 11) ----------------------- */

/* docs/guest-protocol.md: file transfer uses a fixed guest staging directory and the
 * protocol never accepts an arbitrary guest path. On Linux that directory is
 * /tmp/openvm-share. The Windows equivalent of /tmp for a service is its temp
 * directory, so the staging directory is %TEMP%\openvm-share. */

#define FILE_CHUNK_MAX (64 * 1024)
#define FILE_SIZE_MAX (1ULL << 30)
#define WIN_PATH_MAX 512

/* The drive virtio-win's VirtIO-FS service mounts the "openvm" tag on. */
#define WIN_VIRTIOFS_DRIVE L"Z:"
#define WIN_VIRTIOFS_LETTER 'Z'
static WCHAR g_share_dir[WIN_PATH_MAX];

/* Names are already validated to [A-Za-z0-9._-] by safe_component, so they are
 * ASCII and widen byte for byte; no code page conversion is involved. */
static int safe_component(const uint8_t *value, size_t length, size_t max_length, int transfer_id) {
    if (length == 0 || length > max_length || (length == 1 && value[0] == '.') ||
        (length == 2 && value[0] == '.' && value[1] == '.'))
        return 0;
    for (size_t i = 0; i < length; i++) {
        uint8_t c = value[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
              c == '.' || c == '_' || c == '-' || (transfer_id && c == ':')))
            return 0;
    }
    return 1;
}

static int decode_uint_pair(const uint8_t *body, const struct ovmc_pair *pair, uint64_t *value) {
    return pair != NULL && ovmc_uint_from(body + pair->v0, pair->v1 - pair->v0, value);
}

#ifdef OPENVM_REAL_WIN32
static int share_dir_init(void) {
    if (g_share_dir[0])
        return 1;
    WCHAR tmp[WIN_PATH_MAX];
    DWORD n = GetTempPathW(WIN_PATH_MAX, tmp);
    if (n == 0 || n >= WIN_PATH_MAX)
        return 0;
    while (n > 0 && (tmp[n - 1] == L'\\' || tmp[n - 1] == L'/'))
        n--;
    static const WCHAR suffix[] = L"\\openvm-share";
    size_t i = 0;
    for (; i < (size_t)n; i++)
        g_share_dir[i] = tmp[i];
    for (size_t j = 0; suffix[j]; j++) {
        if (i + 1 >= WIN_PATH_MAX)
            return 0;
        g_share_dir[i++] = suffix[j];
    }
    g_share_dir[i] = 0;
    /* Already exists is not an error; a failure to create is caught by the
     * first open, which reports it. */
    CreateDirectoryW(g_share_dir, NULL);
    return 1;
}
#else
static int share_dir_init(void) {
    return 0;
}
#endif

/* Joins the staging directory and an ASCII name into a wide path. */
static int share_path(const char *name, WCHAR *out, size_t cap) {
    if (!share_dir_init())
        return 0;
    size_t i = 0;
    while (g_share_dir[i]) {
        if (i + 1 >= cap)
            return 0;
        out[i] = g_share_dir[i];
        i++;
    }
    if (i + 1 >= cap)
        return 0;
    out[i++] = L'\\';
    for (size_t j = 0; name[j]; j++) {
        if (i + 1 >= cap)
            return 0;
        out[i++] = (WCHAR)(unsigned char)name[j];
    }
    out[i] = 0;
    return 1;
}

/* Reads a probe file out of the staging directory, so the host can prove the
 * shared-folder round trip the same way it does for a 9p mount on Linux. */
static int share_read_probe(const char *share_name, const char *probe, char *out, size_t cap) {
    WCHAR path[WIN_PATH_MAX];
    size_t n = 0;
    for (const WCHAR *p = WIN_VIRTIOFS_DRIVE L"\\"; *p && n < WIN_PATH_MAX - 1; p++)
        path[n++] = *p;
    for (const char *p = share_name; *p && n < WIN_PATH_MAX - 1; p++)
        path[n++] = (WCHAR)*p;
    if (n < WIN_PATH_MAX - 1)
        path[n++] = L'\\';
    for (const char *p = probe; *p && n < WIN_PATH_MAX - 1; p++)
        path[n++] = (WCHAR)*p;
    path[n] = 0;
#ifdef OPENVM_REAL_WIN32
    HANDLE h = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                           FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE)
        return 0;
    DWORD got = 0;
    BOOL ok = ReadFile(h, out, (DWORD)(cap - 1), &got, NULL);
    CloseHandle(h);
    if (!ok)
        return 0;
    out[got] = '\0';
    return 1;
#else
    (void)out;
    (void)cap;
    return 0;
#endif
}

static int make_temp_name(const char *transfer_id, char *out, size_t cap) {
    static const char prefix[] = ".openvm-";
    static const char suffix[] = ".part";
    size_t i = 0;
    for (size_t j = 0; prefix[j]; j++) {
        if (i + 1 >= cap)
            return 0;
        out[i++] = prefix[j];
    }
    for (size_t j = 0; transfer_id[j]; j++) {
        if (i + 1 >= cap)
            return 0;
        out[i++] = transfer_id[j];
    }
    for (size_t j = 0; suffix[j]; j++) {
        if (i + 1 >= cap)
            return 0;
        out[i++] = suffix[j];
    }
    out[i] = '\0';
    return 1;
}

/* Writes one chunk into the staging file, creating it at offset 0 and
 * committing it to its final name on eof. Returns 1 on success. */
static int stage_write(const char *name, const char *temp_name, uint64_t offset,
                       const uint8_t *data, size_t length, int eof) {
#ifdef OPENVM_REAL_WIN32
    WCHAR temp_path[WIN_PATH_MAX], final_path[WIN_PATH_MAX];
    if (!share_path(temp_name, temp_path, WIN_PATH_MAX) ||
        !share_path(name, final_path, WIN_PATH_MAX))
        return 0;

    /* offset 0 creates exclusively, so a stale partial file from a transfer
     * that was never aborted cannot be silently appended to. */
    DWORD disposition = offset == 0 ? CREATE_NEW : OPEN_EXISTING;
    HANDLE f = CreateFileW(temp_path, GENERIC_WRITE, FILE_SHARE_READ, NULL, disposition,
                           FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (f == INVALID_HANDLE_VALUE)
        return 0;

    LARGE_INTEGER size;
    if (!GetFileSizeEx(f, &size) || (uint64_t)size.QuadPart != offset) {
        CloseHandle(f);
        return 0;
    }
    if (offset > 0) {
        LARGE_INTEGER at;
        at.QuadPart = (LONGLONG)offset;
        if (!SetFilePointerEx(f, at, NULL, FILE_BEGIN)) {
            CloseHandle(f);
            return 0;
        }
    }
    size_t written = 0;
    while (written < length) {
        size_t left = length - written;
        DWORD want = (DWORD)(left > 0x10000 ? 0x10000 : left);
        DWORD did = 0;
        if (!WriteFile(f, data + written, want, &did, NULL) || did == 0)
            break;
        written += (size_t)did;
    }
    int failed = written != length || !FlushFileBuffers(f);
    CloseHandle(f);
    if (failed)
        return 0;
    if (eof && !MoveFileExW(temp_path, final_path, MOVEFILE_REPLACE_EXISTING))
        return 0;
    return 1;
#else
    (void)name;
    (void)temp_name;
    (void)offset;
    (void)data;
    (void)length;
    (void)eof;
    return 0;
#endif
}

/* Reads one chunk from a staged file. Returns 1 on success. */
static int stage_read(const char *name, uint64_t offset, uint64_t requested, uint8_t *out,
                      size_t *got, int *eof) {
#ifdef OPENVM_REAL_WIN32
    WCHAR path[WIN_PATH_MAX];
    if (!share_path(name, path, WIN_PATH_MAX))
        return 0;
    HANDLE f = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                           FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (f == INVALID_HANDLE_VALUE)
        return 0;
    LARGE_INTEGER size;
    if (!GetFileSizeEx(f, &size) || size.QuadPart < 0 || (uint64_t)size.QuadPart > FILE_SIZE_MAX ||
        offset > (uint64_t)size.QuadPart) {
        CloseHandle(f);
        return 0;
    }
    if (offset > 0) {
        LARGE_INTEGER at;
        at.QuadPart = (LONGLONG)offset;
        if (!SetFilePointerEx(f, at, NULL, FILE_BEGIN)) {
            CloseHandle(f);
            return 0;
        }
    }
    DWORD did = 0;
    if (!ReadFile(f, out, (DWORD)requested, &did, NULL)) {
        CloseHandle(f);
        return 0;
    }
    CloseHandle(f);
    *got = (size_t)did;
    *eof = (offset + (uint64_t)did) >= (uint64_t)size.QuadPart;
    return 1;
#else
    (void)name;
    (void)offset;
    (void)requested;
    (void)out;
    (void)got;
    (void)eof;
    return 0;
#endif
}

/* Removes an incomplete upload's temporary file. Absent is success. */
static int stage_abort(const char *temp_name) {
#ifdef OPENVM_REAL_WIN32
    WCHAR path[WIN_PATH_MAX];
    if (!share_path(temp_name, path, WIN_PATH_MAX))
        return 0;
    if (DeleteFileW(path))
        return 1;
    return GetLastError() == ERROR_FILE_NOT_FOUND;
#else
    (void)temp_name;
    return 0;
#endif
}

static void file_response(SOCKET fd, uint64_t cid, const char *error, uint64_t offset,
                          const uint8_t *data, size_t length, int eof, int include_data) {
    struct ovmc_out w;
    ovmc_out_init(&w);
    ovmc_whdr(&w, 5, error ? 2 : (include_data ? 4 : 3));
    if (error) {
        ovmc_wtext(&w, "error");
        ovmc_wtext(&w, error);
    } else {
        ovmc_wtext(&w, "offset");
        ovmc_wuint(&w, offset);
        if (include_data) {
            ovmc_wtext(&w, "data");
            ovmc_wbytes(&w, data, length);
        }
        ovmc_wtext(&w, "eof");
        ovmc_wbool(&w, eof);
    }
    ovmc_wtext(&w, "id");
    ovmc_wuint(&w, cid);
    if (w.ok)
        write_reply(fd, T_FILE_REPLY, w.b, w.n);
}

static void handle_file(SOCKET fd, const uint8_t *body, const struct ovmc_pair *pairs, size_t count,
                        uint64_t cid) {
    const struct ovmc_pair *op_pair = ovmc_find(body, pairs, count, "op");
    const struct ovmc_pair *name_pair = ovmc_find(body, pairs, count, "name");
    const uint8_t *op = NULL, *name = NULL;
    size_t op_len = 0, name_len = 0;
    if (op_pair == NULL || name_pair == NULL ||
        !ovmc_text_span(body + op_pair->v0, op_pair->v1 - op_pair->v0, &op, &op_len) ||
        !ovmc_text_span(body + name_pair->v0, name_pair->v1 - name_pair->v0, &name, &name_len) ||
        !safe_component(name, name_len, 240, 0)) {
        file_response(fd, cid, "file request has an invalid op or basename", 0, NULL, 0, 0, 0);
        return;
    }
    char filename[241];
    ovmc_memcpy(filename, name, name_len);
    filename[name_len] = '\0';

    int writing = op_len == 5 && ovmc_memcmp(op, "write", 5) == 0;
    int reading = op_len == 4 && ovmc_memcmp(op, "read", 4) == 0;
    int aborting = op_len == 5 && ovmc_memcmp(op, "abort", 5) == 0;

    if (aborting) {
        const struct ovmc_pair *id_pair = ovmc_find(body, pairs, count, "transferId");
        const uint8_t *tid = NULL;
        size_t id_len = 0;
        char transfer_id[65];
        char temp_name[96];
        if (id_pair == NULL ||
            !ovmc_text_span(body + id_pair->v0, id_pair->v1 - id_pair->v0, &tid, &id_len) ||
            !safe_component(tid, id_len, 64, 1)) {
            file_response(fd, cid, "file abort has an invalid transfer id", 0, NULL, 0, 0, 0);
            return;
        }
        ovmc_memcpy(transfer_id, tid, id_len);
        transfer_id[id_len] = '\0';
        if (!make_temp_name(transfer_id, temp_name, sizeof temp_name)) {
            file_response(fd, cid, "file transfer id is too long", 0, NULL, 0, 0, 0);
            return;
        }
        int ok = stage_abort(temp_name);
        file_response(fd, cid, ok ? NULL : "could not abort file transfer", 0, NULL, 0, 1, 0);
        return;
    }

    if (!writing && !reading) {
        file_response(fd, cid, "file op must be read or write", 0, NULL, 0, 0, 0);
        return;
    }

    uint64_t offset = 0;
    if (!decode_uint_pair(body, ovmc_find(body, pairs, count, "offset"), &offset) ||
        offset > FILE_SIZE_MAX) {
        file_response(fd, cid, "file request has an invalid offset", 0, NULL, 0, 0, 0);
        return;
    }

    if (writing) {
        const struct ovmc_pair *id_pair = ovmc_find(body, pairs, count, "transferId");
        const struct ovmc_pair *data_pair = ovmc_find(body, pairs, count, "data");
        const struct ovmc_pair *eof_pair = ovmc_find(body, pairs, count, "eof");
        const uint8_t *tid = NULL, *data = NULL;
        size_t id_len = 0, data_len = 0;
        int eof = 0;
        char transfer_id[65];
        char temp_name[96];
        if (id_pair == NULL || data_pair == NULL || eof_pair == NULL ||
            !ovmc_text_span(body + id_pair->v0, id_pair->v1 - id_pair->v0, &tid, &id_len) ||
            !safe_component(tid, id_len, 64, 1) ||
            !ovmc_bytes_span(body + data_pair->v0, data_pair->v1 - data_pair->v0, &data,
                             &data_len) ||
            data_len > FILE_CHUNK_MAX ||
            !ovmc_bool_span(body + eof_pair->v0, eof_pair->v1 - eof_pair->v0, &eof) ||
            (data_len == 0 && !eof) || offset > FILE_SIZE_MAX - data_len) {
            file_response(fd, cid, "file write chunk is malformed or too large", 0, NULL, 0, 0, 0);
            return;
        }
        ovmc_memcpy(transfer_id, tid, id_len);
        transfer_id[id_len] = '\0';
        if (!make_temp_name(transfer_id, temp_name, sizeof temp_name)) {
            file_response(fd, cid, "file transfer id is too long", 0, NULL, 0, 0, 0);
            return;
        }
        if (!stage_write(filename, temp_name, offset, data, data_len, eof)) {
            file_response(fd, cid, "file chunk could not be committed", 0, NULL, 0, 0, 0);
            return;
        }
        file_response(fd, cid, NULL, offset + data_len, NULL, 0, eof, 0);
        return;
    }

    uint64_t requested = 0;
    if (!decode_uint_pair(body, ovmc_find(body, pairs, count, "length"), &requested) ||
        requested == 0 || requested > FILE_CHUNK_MAX) {
        file_response(fd, cid, "file read length must be between 1 and 65536", 0, NULL, 0, 0, 0);
        return;
    }
    uint8_t chunk[FILE_CHUNK_MAX];
    size_t got = 0;
    int eof = 0;
    if (!stage_read(filename, offset, requested, chunk, &got, &eof)) {
        file_response(fd, cid, "guest file is missing or not a regular staged file", 0, NULL, 0, 0,
                      0);
        return;
    }
    file_response(fd, cid, NULL, offset + (uint64_t)got, chunk, got, eof, 1);
}
