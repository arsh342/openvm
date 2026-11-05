/* The file service (10/11): bounded chunks in a fixed staging directory. */

static int decode_uint_pair(const uint8_t *body, const struct ovmc_pair *pair, uint64_t *value) {
    return pair && ovmc_uint_from(body + pair->v0, pair->v1 - pair->v0, value);
}

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

static int open_share_directory(void) {
    int tmp = open(OPENVM_SHARE_PARENT, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (tmp < 0)
        return -1;
    if (mkdirat(tmp, OPENVM_SHARE_NAME, 0777) < 0 && errno != EEXIST) {
        close(tmp);
        return -1;
    }
    int directory = openat(tmp, OPENVM_SHARE_NAME, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    close(tmp);
    if (directory < 0)
        return -1;
    struct stat info;
    if (fstat(directory, &info) < 0 || info.st_uid != geteuid()) {
        close(directory);
        errno = EACCES;
        return -1;
    }
    if (fchmod(directory, 01777) < 0) {
        close(directory);
        return -1;
    }
    return directory;
}

static void file_response(int fd, uint64_t cid, const char *error, uint64_t offset,
                          const uint8_t *data, size_t length, int eof, int include_data) {
    struct ovmc_out *w = malloc(sizeof *w);
    if (!w)
        return;
    w->n = 0;
    w->ok = 1;
    ovmc_whdr(w, 5, error ? 2 : (include_data ? 4 : 3));
    if (error) {
        ovmc_wtext(w, "error");
        ovmc_wtext(w, error);
    } else {
        ovmc_wtext(w, "offset");
        ovmc_wuint(w, offset);
        if (include_data) {
            ovmc_wtext(w, "data");
            ovmc_wbytes(w, data, length);
        }
        ovmc_wtext(w, "eof");
        ovmc_wbool(w, eof);
    }
    ovmc_wtext(w, "id");
    ovmc_wuint(w, cid);
    if (w->ok)
        write_reply(fd, T_FILE_REPLY, w->b, w->n);
    free(w);
}

static void handle_file(int fd, const uint8_t *body, const struct ovmc_pair *pairs, size_t count,
                        uint64_t cid) {
    const struct ovmc_pair *op_pair = find_pair(body, pairs, count, "op");
    const struct ovmc_pair *name_pair = find_pair(body, pairs, count, "name");
    const uint8_t *op, *name;
    size_t op_len, name_len;
    if (!op_pair || !name_pair ||
        !ovmc_text_span(body + op_pair->v0, op_pair->v1 - op_pair->v0, &op, &op_len) ||
        !ovmc_text_span(body + name_pair->v0, name_pair->v1 - name_pair->v0, &name, &name_len) ||
        !safe_component(name, name_len, 240, 0)) {
        file_response(fd, cid, "file request has an invalid op or basename", 0, NULL, 0, 0, 0);
        return;
    }
    char filename[241];
    memcpy(filename, name, name_len);
    filename[name_len] = '\0';

    int directory = open_share_directory();
    if (directory < 0) {
        file_response(fd, cid, "could not open guest file staging directory", 0, NULL, 0, 0, 0);
        return;
    }

    int writing = op_len == 5 && memcmp(op, "write", 5) == 0;
    int reading = op_len == 4 && memcmp(op, "read", 4) == 0;
    int aborting = op_len == 5 && memcmp(op, "abort", 5) == 0;
    if (aborting) {
        const struct ovmc_pair *id_pair = find_pair(body, pairs, count, "transferId");
        const uint8_t *transfer_id;
        size_t id_len;
        char temporary[96];
        if (!id_pair ||
            !ovmc_text_span(body + id_pair->v0, id_pair->v1 - id_pair->v0, &transfer_id, &id_len) ||
            !safe_component(transfer_id, id_len, 64, 1)) {
            close(directory);
            file_response(fd, cid, "file abort has an invalid transfer id", 0, NULL, 0, 0, 0);
            return;
        }
        int written =
            snprintf(temporary, sizeof temporary, ".openvm-%.*s.part", (int)id_len, transfer_id);
        int failed = written < 0 || (size_t)written >= sizeof temporary;
        if (!failed && unlinkat(directory, temporary, 0) < 0 && errno != ENOENT)
            failed = 1;
        close(directory);
        file_response(fd, cid, failed ? "could not abort file transfer" : NULL, 0, NULL, 0, 1, 0);
        return;
    }
    if (!writing && !reading) {
        close(directory);
        file_response(fd, cid, "file op must be read or write", 0, NULL, 0, 0, 0);
        return;
    }

    uint64_t offset = 0;
    if (!decode_uint_pair(body, find_pair(body, pairs, count, "offset"), &offset) ||
        offset > FILE_SIZE_MAX) {
        close(directory);
        file_response(fd, cid, "file request has an invalid offset", 0, NULL, 0, 0, 0);
        return;
    }

    if (writing) {
        const struct ovmc_pair *id_pair = find_pair(body, pairs, count, "transferId");
        const struct ovmc_pair *data_pair = find_pair(body, pairs, count, "data");
        const struct ovmc_pair *eof_pair = find_pair(body, pairs, count, "eof");
        const uint8_t *transfer_id, *data;
        size_t id_len, data_len;
        int eof;
        if (!id_pair || !data_pair || !eof_pair ||
            !ovmc_text_span(body + id_pair->v0, id_pair->v1 - id_pair->v0, &transfer_id, &id_len) ||
            !safe_component(transfer_id, id_len, 64, 1) ||
            !ovmc_bytes_span(body + data_pair->v0, data_pair->v1 - data_pair->v0, &data,
                             &data_len) ||
            data_len > FILE_CHUNK_MAX ||
            !ovmc_bool_span(body + eof_pair->v0, eof_pair->v1 - eof_pair->v0, &eof) ||
            (data_len == 0 && !eof) || offset > FILE_SIZE_MAX - data_len) {
            close(directory);
            file_response(fd, cid, "file write chunk is malformed or too large", 0, NULL, 0, 0, 0);
            return;
        }
        char temporary[96];
        int name_written =
            snprintf(temporary, sizeof temporary, ".openvm-%.*s.part", (int)id_len, transfer_id);
        if (name_written < 0 || (size_t)name_written >= sizeof temporary) {
            close(directory);
            file_response(fd, cid, "file transfer id is too long", 0, NULL, 0, 0, 0);
            return;
        }
        int flags = O_WRONLY | O_CLOEXEC | O_NOFOLLOW;
        flags |= offset == 0 ? (O_CREAT | O_EXCL) : 0;
        int file = openat(directory, temporary, flags, 0600);
        struct stat info;
        if (file < 0 || fstat(file, &info) < 0 || !S_ISREG(info.st_mode) ||
            (uint64_t)info.st_size != offset) {
            if (file >= 0)
                close(file);
            close(directory);
            file_response(fd, cid, "file chunk offset does not match transfer state", 0, NULL, 0, 0,
                          0);
            return;
        }
        size_t written = 0;
        while (written < data_len) {
            ssize_t n = pwrite(file, data + written, data_len - written, (off_t)(offset + written));
            if (n < 0 && errno == EINTR)
                continue;
            if (n <= 0)
                break;
            written += (size_t)n;
        }
        int failed = written != data_len || fsync(file) < 0;
        if (!failed && eof)
            failed = fchmod(file, 0644) < 0;
        close(file);
        if (!failed && eof)
            failed =
                renameat(directory, temporary, directory, filename) < 0 || fsync(directory) < 0;
        close(directory);
        if (failed) {
            file_response(fd, cid, "file chunk could not be committed", 0, NULL, 0, 0, 0);
            return;
        }
        file_response(fd, cid, NULL, offset + data_len, NULL, 0, eof, 0);
        return;
    }

    uint64_t requested;
    if (!decode_uint_pair(body, find_pair(body, pairs, count, "length"), &requested) ||
        requested == 0 || requested > FILE_CHUNK_MAX) {
        close(directory);
        file_response(fd, cid, "file read length must be between 1 and 65536", 0, NULL, 0, 0, 0);
        return;
    }
    int file = openat(directory, filename, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    struct stat info;
    if (file < 0 || fstat(file, &info) < 0 || !S_ISREG(info.st_mode) || info.st_size < 0 ||
        (uint64_t)info.st_size > FILE_SIZE_MAX || offset > (uint64_t)info.st_size) {
        if (file >= 0)
            close(file);
        close(directory);
        file_response(fd, cid, "guest file is missing or not a regular staged file", 0, NULL, 0, 0,
                      0);
        return;
    }
    uint8_t chunk[FILE_CHUNK_MAX];
    ssize_t n;
    do {
        n = pread(file, chunk, (size_t)requested, (off_t)offset);
    } while (n < 0 && errno == EINTR);
    close(file);
    close(directory);
    if (n < 0) {
        file_response(fd, cid, "could not read guest file chunk", 0, NULL, 0, 0, 0);
        return;
    }
    uint64_t next = offset + (uint64_t)n;
    file_response(fd, cid, NULL, next, chunk, (size_t)n, next >= (uint64_t)info.st_size, 1);
}
