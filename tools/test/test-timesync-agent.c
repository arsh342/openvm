#define main openvm_tools_main
#include "../guest/openvm-tools.c"
#undef main

#include <assert.h>
#include <pthread.h>
#include <sys/socket.h>

/* Timesync harness: exercises handle_timesync (mirror of test-file-agent.c).
 * Runs as a non-root user, so a valid request is answered either with no
 * error (if the host lets us set the clock) or with the clock-failure reply;
 * malformed requests must always answer an error key. */

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
    handle_timesync(context->fd, context->body, context->pairs, context->count, context->cid);
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
 * each case can assert *which* failure it saw: a non-root run always gets the
 * clock error, while a bad timezone has to fail earlier. */
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
    assert(((uint16_t)frame[6] << 8 | frame[7]) == T_TIMESYNC_REPLY);
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
    char error_text[128] = {0};
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

#define CLOCK_ERROR_PREFIX "could not set the guest clock"

int main(void) {
    struct request *r = calloc(1, sizeof *r);
    assert(r);
    char err[128];

    /* valid request: no error reply, or the documented non-root clock error */
    new_request(r);
    uint64_t now_ms = (uint64_t)time(NULL) * 1000;
    add_value(r, "epochMs", uint_value, &now_ms);
    int failed = dispatch(r, 12, 12, err, sizeof err);
    assert(!failed || strncmp(err, CLOCK_ERROR_PREFIX, sizeof CLOCK_ERROR_PREFIX - 1) == 0);

    /* a timezone the guest knows: the zone is linked before the clock is set,
     * so the link exists even where clock_settime is not permitted */
    new_request(r);
    add_value(r, "epochMs", uint_value, &now_ms);
    add_value(r, "tz", text_value, "Europe/Berlin");
    failed = dispatch(r, 13, 13, err, sizeof err);
    assert(!failed || strncmp(err, CLOCK_ERROR_PREFIX, sizeof CLOCK_ERROR_PREFIX - 1) == 0);
    struct stat localtime_stat;
    assert(lstat(OPENVM_LOCALTIME_PATH, &localtime_stat) == 0);
    char link[512];
    ssize_t link_len = readlink(OPENVM_LOCALTIME_PATH, link, sizeof link - 1);
    assert(link_len > 0);
    link[link_len] = '\0';
    char expected[512];
    snprintf(expected, sizeof expected, "%s/Europe/Berlin", OPENVM_TZINFO_DIR);
    assert(strcmp(link, expected) == 0);

    /* a timezone that tries to escape the zoneinfo root refuses */
    new_request(r);
    add_value(r, "epochMs", uint_value, &now_ms);
    add_value(r, "tz", text_value, "../etc/passwd");
    assert(dispatch(r, 14, 14, err, sizeof err) == 1);
    assert(strncmp(err, CLOCK_ERROR_PREFIX, sizeof CLOCK_ERROR_PREFIX - 1) != 0);

    /* a well-formed zone the guest does not know refuses */
    new_request(r);
    add_value(r, "epochMs", uint_value, &now_ms);
    add_value(r, "tz", text_value, "Europe/Nowhere");
    assert(dispatch(r, 15, 15, err, sizeof err) == 1);
    assert(strncmp(err, CLOCK_ERROR_PREFIX, sizeof CLOCK_ERROR_PREFIX - 1) != 0);

    /* missing epochMs refuses */
    new_request(r);
    assert(dispatch(r, 16, 16, err, sizeof err) == 1);

    /* non-integer epochMs refuses */
    new_request(r);
    add_value(r, "epochMs", text_value, "not-a-number");
    assert(dispatch(r, 17, 17, err, sizeof err) == 1);

    /* absurd epochMs (past the year-9999 sanity cap) refuses */
    new_request(r);
    uint64_t huge = UINT64_MAX;
    add_value(r, "epochMs", uint_value, &huge);
    assert(dispatch(r, 18, 18, err, sizeof err) == 1);

    free(r);
    printf("timesync agent harness: ok\n");
    return 0;
}
