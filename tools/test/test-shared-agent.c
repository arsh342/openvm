#define main openvm_tools_main
#include "../guest/openvm-tools.c"
#undef main

#include <assert.h>
#include <pthread.h>
#include <sys/socket.h>

/* Shared-folder harness: exercises handle_shared (mirror of test-timesync-agent.c).
 * The host has no virtio-fs, so a well-formed mount can only fail in the shell — every
 * malformed field must be refused before the shell is reached. */

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
    handle_shared(context->fd, context->body, context->pairs, context->count, context->cid);
    return NULL;
}

/* Extracts a CBOR text value: the value bytes include the head and length. */
static void text_bytes(const uint8_t *v, size_t vlen, char *out, size_t cap) {
    out[0] = '\0';
    if (vlen < 1)
        return;
    uint8_t head = v[0];
    if ((head >> 5) != 3)
        return;
    size_t len, offset;
    uint8_t ai = head & 0x1f;
    if (ai < 24) {
        len = ai;
        offset = 1;
    } else if (ai == 24 && vlen >= 2) {
        len = v[1];
        offset = 2;
    } else if (ai == 25 && vlen >= 3) {
        len = ((size_t)v[1] << 8) | v[2];
        offset = 3;
    } else if (ai == 26 && vlen >= 5) {
        len = ((size_t)v[1] << 24) | ((size_t)v[2] << 16) | ((size_t)v[3] << 8) | v[4];
        offset = 5;
    } else {
        return;
    }
    if (offset + len > vlen)
        return;
    size_t copy = len < cap - 1 ? len : cap - 1;
    memcpy(out, v + offset, copy);
    out[copy] = '\0';
}

/* Returns 1 when the reply carried an error key and copies the error text, so
 * each case can assert *which* refusal it saw. */
static int dispatch(struct request *r, uint64_t cid, uint64_t expect_cid, char *error_out,
                    size_t error_cap) {
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
    assert(((uint16_t)frame[6] << 8 | frame[7]) == T_SHARED_REPLY);
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
    int saw_error = 0, saw_id = 0;
    uint64_t id_value = 0;
    char error_text[256] = {0};
    for (size_t i = 0; i < count && c.ok; i++) {
        uint8_t kh = c.p[c.i++];
        size_t kn = kh & 0x1f;
        const uint8_t *key = c.p + c.i;
        c.i += kn;
        size_t v0 = c.i;
        ovmc_parse_val(&c);
        size_t vlen = c.i - v0;
        if (kn == 5 && memcmp(key, "error", 5) == 0) {
            saw_error = 1;
            text_bytes(c.p + v0, vlen, error_text, sizeof error_text);
        }
        if (kn == 2 && memcmp(key, "id", 2) == 0) {
            saw_id = ovmc_uint_from(c.p + v0, vlen, &id_value) && id_value == expect_cid;
        }
    }
    assert(c.ok && c.i == c.n);
    assert(saw_id); /* the correlation id must travel last, unchanged */
    if (error_out && error_cap) {
        size_t len = strlen(error_text);
        size_t copy = len < error_cap - 1 ? len : error_cap - 1;
        memcpy(error_out, error_text, copy);
        error_out[copy] = '\0';
    }
    return saw_error;
}

static void expect_error(struct request *r, uint64_t cid, const char *prefix) {
    char err[256];
    assert(dispatch(r, cid, cid, err, sizeof err) == 1);
    assert(strncmp(err, prefix, strlen(prefix)) == 0);
}

int main(void) {
    struct request *r = calloc(1, sizeof *r);
    assert(r);
    char err[256];

    /* The mount path lives in a throwaway directory. This host has no
     * virtio-fs, so a well-formed mount reaches the shell and fails there. */
    const char *mount_path = getenv("OVM_TEST_MOUNT_PATH");
    assert(mount_path && mount_path[0] == '/');

    new_request(r);
    add_value(r, "op", text_value, "mount");
    add_value(r, "name", text_value, "s0123456789abcdef");
    add_value(r, "path", text_value, mount_path);
    add_value(r, "probe", text_value, "probe.txt");
    assert(dispatch(r, 20, 20, err, sizeof err) == 1);
    assert(strncmp(err, "mount failed", 12) == 0);

    /* an unmount of a path that is not mounted fails in the shell too */
    new_request(r);
    add_value(r, "op", text_value, "unmount");
    add_value(r, "path", text_value, mount_path);
    assert(dispatch(r, 21, 21, err, sizeof err) == 1);
    assert(strncmp(err, "umount failed", 12) == 0);

    /* a request without an op refuses */
    new_request(r);
    expect_error(r, 22, "shared request has no usable op");

    /* an unknown op refuses */
    new_request(r);
    add_value(r, "op", text_value, "chroot");
    expect_error(r, 23, "unknown shared op");

    /* a relative guest path refuses */
    new_request(r);
    add_value(r, "op", text_value, "mount");
    add_value(r, "name", text_value, "s0123456789abcdef");
    add_value(r, "path", text_value, "mnt/share");
    expect_error(r, 24, "shared request has no usable path");

    /* a guest path that tries to escape refuses */
    new_request(r);
    add_value(r, "op", text_value, "mount");
    add_value(r, "name", text_value, "s0123456789abcdef");
    add_value(r, "path", text_value, "/mnt/../../etc");
    expect_error(r, 25, "shared request has no usable path");

    /* a missing share name refuses */
    new_request(r);
    add_value(r, "op", text_value, "mount");
    add_value(r, "path", text_value, mount_path);
    expect_error(r, 26, "shared request has no usable share name");

    /* a share name that could reach the shell or climb the tree refuses */
    new_request(r);
    add_value(r, "op", text_value, "mount");
    add_value(r, "name", text_value, "../etc';reboot'");
    add_value(r, "path", text_value, mount_path);
    expect_error(r, 27, "shared request has no usable share name");

    /* a probe name with a separator refuses */
    new_request(r);
    add_value(r, "op", text_value, "mount");
    add_value(r, "name", text_value, "s0123456789abcdef");
    add_value(r, "path", text_value, mount_path);
    add_value(r, "probe", text_value, "sub/probe.txt");
    expect_error(r, 28, "shared request has no usable probe name");

    free(r);
    printf("shared agent harness: ok\n");
    return 0;
}
