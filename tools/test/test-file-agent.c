#define main openvm_tools_main
#include "../guest/openvm-tools.c"
#undef main

#include <assert.h>
#include <pthread.h>
#include <sys/socket.h>

struct request {
    struct ovmc_out body;
    struct ovmc_pair pairs[8];
    size_t count;
};

static void add_value(struct request *r, const char *key,
                      void (*encode)(struct ovmc_out *, const void *), const void *value) {
    struct ovmc_pair *p = &r->pairs[r->count++];
    p->k0 = r->body.n;
    ovmc_wtext(&r->body, key);
    p->k1 = r->body.n;
    p->v0 = r->body.n;
    encode(&r->body, value);
    p->v1 = r->body.n;
    p->drop = 0;
}

static void text_value(struct ovmc_out *w, const void *v) {
    ovmc_wtext(w, v);
}
static void uint_value(struct ovmc_out *w, const void *v) {
    ovmc_wuint(w, *(const uint64_t *)v);
}
static void bytes_value(struct ovmc_out *w, const void *v) {
    const struct {
        const uint8_t *data;
        size_t length;
    } *b = v;
    ovmc_wbytes(w, b->data, b->length);
}
static void bool_value(struct ovmc_out *w, const void *v) {
    ovmc_wbool(w, *(const int *)v);
}

static struct request *new_request(struct request *r) {
    memset(r, 0, sizeof *r);
    r->body.ok = 1;
    ovmc_whdr(&r->body, 5, 0); /* overwritten with exact pair count before dispatch */
    return r;
}

struct dispatch_context {
    int fd;
    const uint8_t *body;
    const struct ovmc_pair *pairs;
    size_t count;
    uint64_t cid;
};

static void *dispatch_worker(void *opaque) {
    struct dispatch_context *context = opaque;
    handle_file(context->fd, context->body, context->pairs, context->count, context->cid);
    return NULL;
}

static void dispatch(struct request *r, uint64_t cid, int expect_error,
                     const uint8_t *expected_data, size_t expected_length, int expected_eof) {
    r->body.b[0] = (uint8_t)(0xa0 | r->count);
    int sockets[2];
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
    struct dispatch_context context = {sockets[0], r->body.b, r->pairs, r->count, cid};
    pthread_t worker;
    assert(pthread_create(&worker, NULL, dispatch_worker, &context) == 0);
    uint8_t *frame = malloc(OVMC_FRAME_HEADER + OVMC_MAX_PAYLOAD);
    assert(frame);
    size_t got = 0;
    while (got < OVMC_FRAME_HEADER) {
        ssize_t n = read(sockets[1], frame + got, OVMC_FRAME_HEADER - got);
        assert(n > 0);
        got += (size_t)n;
    }
    assert(memcmp(frame, OVMC_MAGIC, 4) == 0);
    assert(((uint16_t)frame[6] << 8 | frame[7]) == T_FILE_REPLY);
    size_t payload = ((size_t)frame[10] << 24) | ((size_t)frame[11] << 16) |
                     ((size_t)frame[12] << 8) | frame[13];
    while (got < OVMC_FRAME_HEADER + payload) {
        ssize_t n = read(sockets[1], frame + got, OVMC_FRAME_HEADER + payload - got);
        assert(n > 0);
        got += (size_t)n;
    }
    assert(pthread_join(worker, NULL) == 0);
    close(sockets[0]);
    close(sockets[1]);

    struct ovmc_cur c = {frame + OVMC_FRAME_HEADER, payload, 0, 1};
    uint8_t head = c.p[c.i++];
    assert((head >> 5) == 5);
    size_t count = head & 0x1f;
    int saw_error = 0, saw_data = 0, saw_eof = 0;
    for (size_t i = 0; i < count && c.ok; i++) {
        uint8_t kh = c.p[c.i++];
        size_t kn = kh & 0x1f;
        const uint8_t *key = c.p + c.i;
        c.i += kn;
        size_t v0 = c.i;
        ovmc_parse_val(&c);
        size_t vlen = c.i - v0;
        if (kn == 5 && memcmp(key, "error", 5) == 0)
            saw_error = 1;
        if (kn == 3 && memcmp(key, "eof", 3) == 0) {
            int eof;
            saw_eof = ovmc_bool_span(c.p + v0, vlen, &eof) && eof == expected_eof;
        }
        if (kn == 4 && memcmp(key, "data", 4) == 0) {
            const uint8_t *data;
            size_t length;
            saw_data = ovmc_bytes_span(c.p + v0, vlen, &data, &length) &&
                       length == expected_length && memcmp(data, expected_data, length) == 0;
        }
    }
    assert(c.ok && c.i == c.n);
    assert(saw_error == expect_error);
    if (!expect_error && expected_data)
        assert(saw_data);
    if (!expect_error && expected_eof >= 0)
        assert(saw_eof);
    free(frame);
}

int main(void) {
    const uint8_t first[] = {0, 1};
    const uint8_t second[] = {2, 255};
    struct request *r = calloc(1, sizeof *r);
    assert(r);
    new_request(r);
    add_value(r, "op", text_value, "write");
    add_value(r, "name", text_value, "sample.bin");
    add_value(r, "transferId", text_value, "transfer-1");
    uint64_t zero = 0;
    add_value(r, "offset", uint_value, &zero);
    const struct {
        const uint8_t *data;
        size_t length;
    } first_chunk = {first, sizeof first};
    add_value(r, "data", bytes_value, &first_chunk);
    int eof = 0;
    add_value(r, "eof", bool_value, &eof);
    dispatch(r, 1, 0, NULL, 0, -1);

    new_request(r);
    add_value(r, "op", text_value, "abort");
    add_value(r, "name", text_value, "sample.bin");
    add_value(r, "transferId", text_value, "transfer-1");
    dispatch(r, 2, 0, NULL, 0, -1);
    char temporary_path[512];
    snprintf(temporary_path, sizeof temporary_path, "%s/%s/.openvm-transfer-1.part",
             OPENVM_SHARE_PARENT, OPENVM_SHARE_NAME);
    assert(access(temporary_path, F_OK) != 0);

    new_request(r);
    add_value(r, "op", text_value, "write");
    add_value(r, "name", text_value, "sample.bin");
    add_value(r, "transferId", text_value, "transfer-1");
    add_value(r, "offset", uint_value, &zero);
    add_value(r, "data", bytes_value, &first_chunk);
    add_value(r, "eof", bool_value, &eof);
    dispatch(r, 3, 0, NULL, 0, -1);

    new_request(r);
    add_value(r, "op", text_value, "write");
    add_value(r, "name", text_value, "sample.bin");
    add_value(r, "transferId", text_value, "transfer-1");
    uint64_t two = 2;
    add_value(r, "offset", uint_value, &two);
    const struct {
        const uint8_t *data;
        size_t length;
    } second_chunk = {second, sizeof second};
    add_value(r, "data", bytes_value, &second_chunk);
    eof = 1;
    add_value(r, "eof", bool_value, &eof);
    dispatch(r, 4, 0, NULL, 0, -1);

    const uint8_t all[] = {0, 1, 2, 255};
    new_request(r);
    add_value(r, "op", text_value, "read");
    add_value(r, "name", text_value, "sample.bin");
    add_value(r, "offset", uint_value, &zero);
    uint64_t length = 16;
    add_value(r, "length", uint_value, &length);
    dispatch(r, 5, 0, all, sizeof all, 1);

    new_request(r);
    add_value(r, "op", text_value, "read");
    add_value(r, "name", text_value, "../etc/passwd");
    add_value(r, "offset", uint_value, &zero);
    add_value(r, "length", uint_value, &length);
    dispatch(r, 6, 1, NULL, 0, -1);

    new_request(r);
    add_value(r, "op", text_value, "read");
    add_value(r, "name", text_value, "missing.bin");
    add_value(r, "offset", uint_value, &zero);
    add_value(r, "length", uint_value, &length);
    dispatch(r, 7, 1, NULL, 0, -1);

    uint8_t boundary[FILE_CHUNK_MAX];
    for (size_t i = 0; i < sizeof boundary; i++)
        boundary[i] = (uint8_t)i;
    const struct {
        const uint8_t *data;
        size_t length;
    } full_chunk = {boundary, sizeof boundary};
    new_request(r);
    add_value(r, "op", text_value, "write");
    add_value(r, "name", text_value, "boundary.bin");
    add_value(r, "transferId", text_value, "boundary-1");
    add_value(r, "offset", uint_value, &zero);
    add_value(r, "data", bytes_value, &full_chunk);
    eof = 0;
    add_value(r, "eof", bool_value, &eof);
    dispatch(r, 8, 0, NULL, 0, -1);

    uint64_t full_offset = FILE_CHUNK_MAX;
    const uint8_t last_byte[] = {0x5a};
    const struct {
        const uint8_t *data;
        size_t length;
    } final_chunk = {last_byte, sizeof last_byte};
    new_request(r);
    add_value(r, "op", text_value, "write");
    add_value(r, "name", text_value, "boundary.bin");
    add_value(r, "transferId", text_value, "boundary-1");
    add_value(r, "offset", uint_value, &full_offset);
    add_value(r, "data", bytes_value, &final_chunk);
    eof = 1;
    add_value(r, "eof", bool_value, &eof);
    dispatch(r, 9, 0, NULL, 0, -1);

    new_request(r);
    add_value(r, "op", text_value, "read");
    add_value(r, "name", text_value, "boundary.bin");
    add_value(r, "offset", uint_value, &zero);
    length = FILE_CHUNK_MAX;
    add_value(r, "length", uint_value, &length);
    dispatch(r, 10, 0, boundary, sizeof boundary, 0);

    new_request(r);
    add_value(r, "op", text_value, "read");
    add_value(r, "name", text_value, "boundary.bin");
    add_value(r, "offset", uint_value, &full_offset);
    length = 1;
    add_value(r, "length", uint_value, &length);
    dispatch(r, 11, 0, last_byte, sizeof last_byte, 1);

    const struct {
        const uint8_t *data;
        size_t length;
    } empty_chunk = {NULL, 0};
    new_request(r);
    add_value(r, "op", text_value, "write");
    add_value(r, "name", text_value, "empty.bin");
    add_value(r, "transferId", text_value, "empty-1");
    add_value(r, "offset", uint_value, &zero);
    add_value(r, "data", bytes_value, &empty_chunk);
    eof = 1;
    add_value(r, "eof", bool_value, &eof);
    dispatch(r, 12, 0, NULL, 0, -1);

    new_request(r);
    add_value(r, "op", text_value, "read");
    add_value(r, "name", text_value, "empty.bin");
    add_value(r, "offset", uint_value, &zero);
    length = 1;
    add_value(r, "length", uint_value, &length);
    const uint8_t no_bytes[] = {0};
    dispatch(r, 13, 0, no_bytes, 0, 1);

    new_request(r);
    add_value(r, "op", text_value, "read");
    add_value(r, "name", text_value, "sample.bin");
    uint64_t invalid_offset = 5;
    add_value(r, "offset", uint_value, &invalid_offset);
    add_value(r, "length", uint_value, &length);
    dispatch(r, 14, 1, NULL, 0, -1);

    new_request(r);
    add_value(r, "op", text_value, "write");
    add_value(r, "name", text_value, "invalid.bin");
    add_value(r, "transferId", text_value, "invalid-1");
    add_value(r, "offset", uint_value, &zero);
    add_value(r, "data", bytes_value, &empty_chunk);
    eof = 0;
    add_value(r, "eof", bool_value, &eof);
    dispatch(r, 15, 1, NULL, 0, -1);

    const uint8_t overflow_byte[] = {1};
    const struct {
        const uint8_t *data;
        size_t length;
    } overflow_chunk = {overflow_byte, 1};
    uint64_t max_size = FILE_SIZE_MAX;
    new_request(r);
    add_value(r, "op", text_value, "write");
    add_value(r, "name", text_value, "invalid.bin");
    add_value(r, "transferId", text_value, "invalid-2");
    add_value(r, "offset", uint_value, &max_size);
    add_value(r, "data", bytes_value, &overflow_chunk);
    eof = 1;
    add_value(r, "eof", bool_value, &eof);
    dispatch(r, 16, 1, NULL, 0, -1);

    char symlink_path[512];
    snprintf(symlink_path, sizeof symlink_path, "%s/%s/symlink.bin", OPENVM_SHARE_PARENT,
             OPENVM_SHARE_NAME);
    assert(symlink("/etc/passwd", symlink_path) == 0);
    new_request(r);
    add_value(r, "op", text_value, "read");
    add_value(r, "name", text_value, "symlink.bin");
    add_value(r, "offset", uint_value, &zero);
    length = 16;
    add_value(r, "length", uint_value, &length);
    dispatch(r, 17, 1, NULL, 0, -1);
    free(r);
    puts("file agent: chunk boundaries, empty/binary files, abort, and path validation passed");
    return 0;
}
