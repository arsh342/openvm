/* ovmc_codec.h — the OVMC frame and CBOR-subset codec, shared by every guest
 * agent (Linux: openvm-tools.c, Windows: openvm-tools-win.c).
 *
 * Portable C99. No POSIX, no libc beyond memcpy/strlen, no allocation. The
 * transport is NOT here: each agent supplies its own read/write because the
 * socket API differs (BSD sockets vs Winsock) even though the bytes on the
 * wire are identical.
 *
 * This file is the single source of truth for the wire format described in
 * docs/guest-protocol.md. If the two agents ever disagree about a frame, the bug is
 * in one of them including a different copy of this header.
 */
#ifndef OVMC_CODEC_H
#define OVMC_CODEC_H

/* Freestanding: no libc. The Windows agent is built with -nostdlib against the
 * MSVC target, which has no <string.h>, so the handful of primitives the codec
 * needs are defined here. They are trivial and inlined. */
#include <stddef.h>
#include <stdint.h>

static void *ovmc_memcpy(void *dst, const void *src, size_t n) {
    uint8_t *d = (uint8_t *)dst;
    const uint8_t *s = (const uint8_t *)src;
    for (size_t i = 0; i < n; i++)
        d[i] = s[i];
    return dst;
}

static void ovmc_memset_zero(void *dst, size_t n) {
    uint8_t *d = (uint8_t *)dst;
    for (size_t i = 0; i < n; i++)
        d[i] = 0;
}

static int ovmc_memcmp(const void *a, const void *b, size_t n) {
    const uint8_t *x = (const uint8_t *)a;
    const uint8_t *y = (const uint8_t *)b;
    for (size_t i = 0; i < n; i++)
        if (x[i] != y[i])
            return (int)x[i] - (int)y[i];
    return 0;
}

static size_t ovmc_strlen(const char *s) {
    size_t n = 0;
    while (s[n] != '\0')
        n++;
    return n;
}

static int ovmc_strcmp(const char *a, const char *b) {
    while (*a && *a == *b) {
        a++;
        b++;
    }
    return (int)(unsigned char)*a - (int)(unsigned char)*b;
}

/* Substring search. Returns NULL when `needle` is absent, like strstr. */
static const char *ovmc_strstr(const char *hay, const char *needle) {
    if (*needle == '\0')
        return hay;
    for (; *hay; hay++) {
        const char *h = hay;
        const char *n = needle;
        while (*h && *n && *h == *n) {
            h++;
            n++;
        }
        if (*n == '\0')
            return hay;
    }
    return NULL;
}

#define OVMC_FRAME_HEADER 14
#define OVMC_MAX_PAYLOAD (1u << 20) /* 1 MiB, docs/guest-protocol.md frame rule 4 */
#define OVMC_MAX_PAIRS 512
#define OVMC_VERSION 1
#define OVMC_VSOCK_PORT 52

/* Message catalogue, version 1. Append-only: never reassign a number. */
#define T_HELLO 1
#define T_HELLO_REPLY 2
#define T_ECHO_REQUEST 3
#define T_ECHO_REPLY 4
#define T_ERROR 5
#define T_VM_REQUEST 6
#define T_VM_REPLY 7
#define T_CLIPBOARD_REQUEST 8
#define T_CLIPBOARD_REPLY 9
#define T_FILE_REQUEST 10
#define T_FILE_REPLY 11
#define T_TIMESYNC_REQUEST 12
#define T_TIMESYNC_REPLY 13
#define T_SHARED_REQUEST 14
#define T_SHARED_REPLY 15
#define T_SUSPEND_REQUEST 16
#define T_SUSPEND_REPLY 17
#define T_DRAG_REQUEST 18
#define T_DRAG_REPLY 19
#define T_PRINTER_REQUEST 20
#define T_PRINTER_REPLY 21
#define T_AUDIO_REQUEST 22
#define T_AUDIO_REPLY 23
#define T_DISPLAY_REQUEST 24
#define T_DISPLAY_REPLY 25

/* Error numbers carried in `error.errno`. */
#define OVMC_ERR_UNKNOWN_TYPE 1
#define OVMC_ERR_BAD_PAYLOAD 2
#define OVMC_ERR_UNSUPPORTED_VERSION 3

static const uint8_t OVMC_MAGIC[4] = {'O', 'V', 'M', 'C'};

/* ---------- writer ------------------------------------------------------ */

struct ovmc_out {
    uint8_t b[OVMC_MAX_PAYLOAD];
    size_t n;
    int ok;
};

static void ovmc_out_init(struct ovmc_out *w) {
    w->n = 0;
    w->ok = 1;
}

static void ovmc_w8(struct ovmc_out *w, int v) {
    if (w->ok && w->n < sizeof w->b)
        w->b[w->n++] = (uint8_t)v;
    else
        w->ok = 0;
}

static void ovmc_wbe(struct ovmc_out *w, uint64_t v, int width) {
    for (int k = width - 1; k >= 0; k--)
        ovmc_w8(w, (int)((v >> (8 * k)) & 0xff));
}

/* CBOR head: major type + minimally encoded argument. */
static void ovmc_whdr(struct ovmc_out *w, uint8_t major, uint64_t val) {
    uint8_t m = (uint8_t)(major << 5);
    if (val < 24) {
        ovmc_w8(w, m | (int)val);
    } else if (val <= 0xff) {
        ovmc_w8(w, m | 24);
        ovmc_w8(w, (int)val);
    } else if (val <= 0xffff) {
        ovmc_w8(w, m | 25);
        ovmc_wbe(w, val, 2);
    } else if (val <= 0xffffffffu) {
        ovmc_w8(w, m | 26);
        ovmc_wbe(w, val, 4);
    } else {
        ovmc_w8(w, m | 27);
        ovmc_wbe(w, val, 8);
    }
}

static void ovmc_wtextn(struct ovmc_out *w, const uint8_t *s, size_t n) {
    ovmc_whdr(w, 3, n);
    for (size_t i = 0; i < n; i++)
        ovmc_w8(w, s[i]);
}

static void ovmc_wtext(struct ovmc_out *w, const char *s) {
    ovmc_wtextn(w, (const uint8_t *)s, ovmc_strlen(s));
}

static void ovmc_wuint(struct ovmc_out *w, uint64_t v) {
    ovmc_whdr(w, 0, v);
}
static void ovmc_wbool(struct ovmc_out *w, int b) {
    ovmc_w8(w, b ? 0xf5 : 0xf4);
}

static void ovmc_wbytes(struct ovmc_out *w, const uint8_t *b, size_t n) {
    ovmc_whdr(w, 2, n);
    for (size_t i = 0; i < n; i++)
        ovmc_w8(w, b[i]);
}

/* ---------- reader cursor ----------------------------------------------- */

struct ovmc_cur {
    const uint8_t *p;
    size_t n;
    size_t i;
    int ok;
};

static uint64_t ovmc_get_be(struct ovmc_cur *c, size_t width) {
    if (!c->ok || c->n - c->i < width) {
        c->ok = 0;
        return 0;
    }
    uint64_t v = 0;
    for (size_t k = 0; k < width; k++)
        v = (v << 8) | c->p[c->i + k];
    c->i += width;
    return v;
}

/* Canonical (minimal) uint from a header byte at p[0] spanning `span` bytes. */
static int ovmc_uint_from(const uint8_t *p, size_t span, uint64_t *out) {
    uint8_t h = p[0];
    if ((h >> 5) != 0)
        return 0;
    int minor = h & 0x1f;
    if (minor < 24) {
        *out = (uint64_t)minor;
        return 1;
    }
    if (minor > 27)
        return 0;
    size_t w = (size_t)1u << (minor - 24); /* 24..27 -> 1,2,4,8 */
    if (span != w + 1)
        return 0; /* the Swift codec encodes uints minimally */
    uint64_t v = 0;
    for (size_t k = 0; k < w; k++)
        v = (v << 8) | p[1 + k];
    *out = v;
    return 1;
}

/* One key/value span pair inside a top-level map. */
struct ovmc_pair {
    size_t k0, k1; /* raw key span: header byte + text content */
    size_t v0, v1; /* raw value span */
    int drop;      /* the Linux agent excludes id pairs from an echo */
};

/* Skip one complete CBOR item, honouring the subset the protocol allows
 * (no floats, no tags, no indefinite lengths). */
static void ovmc_parse_val(struct ovmc_cur *c) {
    if (!c->ok || c->i >= c->n) {
        c->ok = 0;
        return;
    }
    uint8_t h = c->p[c->i++];
    uint8_t major = (uint8_t)(h >> 5);
    int minor = h & 0x1f;
    if (minor == 31) { /* indefinite length: outside the subset */
        c->ok = 0;
        return;
    }
    uint64_t arg = 0;
    if (minor < 24) {
        arg = (uint64_t)minor;
    } else if (minor <= 27) {
        arg = ovmc_get_be(c, (size_t)1u << (minor - 24));
        if (!c->ok)
            return;
    } else {
        c->ok = 0;
        return;
    }
    switch (major) {
    case 0: /* uint */
    case 1: /* negative int */
        return;
    case 2: /* byte string */
    case 3: /* text string */
        if (c->n - c->i < arg) {
            c->ok = 0;
            return;
        }
        c->i += (size_t)arg;
        return;
    case 4: /* array */
        for (uint64_t k = 0; k < arg && c->ok; k++)
            ovmc_parse_val(c);
        return;
    case 5: /* map: every key is text */
        for (uint64_t k = 0; k < arg && c->ok; k++) {
            if (c->i >= c->n || (c->p[c->i] >> 5) != 3) {
                c->ok = 0;
                return;
            }
            ovmc_parse_val(c);
            ovmc_parse_val(c);
        }
        return;
    case 7: /* false, true and null only */
        if (h == 0xf4 || h == 0xf5 || h == 0xf6)
            return;
        c->ok = 0;
        return;
    default: /* tags (6) and anything else are outside the subset */
        c->ok = 0;
        return;
    }
}

/* Read a text value span (header + content) into a NUL-terminated buffer. */
static int ovmc_text_span(const uint8_t *p, size_t span, const uint8_t **text, size_t *length) {
    if (span < 1 || (p[0] >> 5) != 3)
        return 0;
    int minor = p[0] & 0x1f;
    size_t hdr = 1, len = 0;
    if (minor < 24) {
        len = (size_t)minor;
    } else if (minor <= 27) {
        size_t w = (size_t)1u << (minor - 24);
        if (span < 1 + w)
            return 0;
        for (size_t k = 0; k < w; k++)
            len = (len << 8) | p[1 + k];
        hdr = 1 + w;
    } else {
        return 0;
    }
    if (span != hdr + len)
        return 0;
    *text = p + hdr;
    *length = len;
    return 1;
}

static int ovmc_bytes_span(const uint8_t *p, size_t span, const uint8_t **bytes, size_t *length) {
    if (span < 1 || (p[0] >> 5) != 2)
        return 0;
    int minor = p[0] & 0x1f;
    size_t hdr = 1, len = 0;
    if (minor < 24) {
        len = (size_t)minor;
    } else if (minor <= 27) {
        size_t w = (size_t)1u << (minor - 24);
        if (span < 1 + w)
            return 0;
        for (size_t k = 0; k < w; k++)
            len = (len << 8) | p[1 + k];
        hdr = 1 + w;
    } else {
        return 0;
    }
    if (span != hdr + len)
        return 0;
    *bytes = p + hdr;
    *length = len;
    return 1;
}

static int ovmc_bool_span(const uint8_t *p, size_t span, int *value) {
    if (span != 1)
        return 0;
    if (p[0] == 0xf5) {
        *value = 1;
        return 1;
    }
    if (p[0] == 0xf4) {
        *value = 0;
        return 1;
    }
    return 0;
}

/* Does this pair's key equal `key`? */
static int ovmc_key_is(const struct ovmc_pair *pair, const uint8_t *body, const char *key) {
    const uint8_t *k = NULL;
    size_t klen = 0;
    if (!ovmc_text_span(body + pair->k0, pair->k1 - pair->k0, &k, &klen))
        return 0;
    size_t want = ovmc_strlen(key);
    return klen == want && ovmc_memcmp(k, key, want) == 0;
}

static const struct ovmc_pair *ovmc_find(const uint8_t *body, const struct ovmc_pair *pairs,
                                         size_t count, const char *key) {
    for (size_t i = 0; i < count; i++)
        if (ovmc_key_is(&pairs[i], body, key))
            return &pairs[i];
    return NULL;
}

/* ---------- frame ------------------------------------------------------- */

/* Encode a frame header into `out` (14 bytes). Returns 0 on bad length. */
/* A dropped item's name on Windows. Beyond leaving the folder, this refuses what
 * Windows would quietly change or reinterpret: stream and wildcard characters,
 * trailing dots and spaces, and the device names (NUL, COM1, ...), which it
 * resolves whatever the extension. Bytes above ASCII are UTF-8 and pass. */
static int ovmc_valid_windows_item(const uint8_t *s, size_t n) {
    if (n == 0 || n > 255 || s[n - 1] == '.' || s[n - 1] == ' ')
        return 0;
    for (size_t i = 0; i < n; i++) {
        uint8_t c = s[i];
        if (c < 0x20 || c == 0x7f || c == '/' || c == '\\' || c == ':' || c == '*' || c == '?' ||
            c == '"' || c == '<' || c == '>' || c == '|')
            return 0;
    }
    static const char *const devices[] = {"CON", "PRN", "AUX", "NUL", "COM", "LPT"};
    size_t stem = 0;
    while (stem < n && s[stem] != '.')
        stem++;
    for (size_t d = 0; d < sizeof devices / sizeof devices[0]; d++) {
        size_t want = d < 4 ? 3 : 4; /* COM and LPT take a digit */
        if (stem != want)
            continue;
        int same = 1;
        for (size_t i = 0; i < 3; i++) {
            uint8_t c = s[i];
            if (c >= 'a' && c <= 'z')
                c = (uint8_t)(c - 'a' + 'A');
            same &= c == (uint8_t)devices[d][i];
        }
        if (same && (want == 3 || (s[3] >= '0' && s[3] <= '9')))
            return 0;
    }
    return 1;
}

static int ovmc_frame_header(uint8_t out[OVMC_FRAME_HEADER], uint16_t type, uint32_t len) {
    if (len > OVMC_MAX_PAYLOAD)
        return 0;
    ovmc_memcpy(out, OVMC_MAGIC, 4);
    out[4] = 0;
    out[5] = OVMC_VERSION;
    out[6] = (uint8_t)(type >> 8);
    out[7] = (uint8_t)type;
    out[8] = 0;
    out[9] = 0; /* flags must be 0 in version 1 */
    out[10] = (uint8_t)(len >> 24);
    out[11] = (uint8_t)(len >> 16);
    out[12] = (uint8_t)(len >> 8);
    out[13] = (uint8_t)len;
    return 1;
}

struct ovmc_header {
    uint16_t version;
    uint16_t type;
    uint16_t flags;
    uint32_t length;
    int ok; /* 0 when a receiver stop rule fired */
};

/* Validate a received header against the receiver rules in docs/guest-protocol.md.
 * Any violation is a stop: the connection closes and no resync is attempted. */
static struct ovmc_header ovmc_parse_header(const uint8_t raw[OVMC_FRAME_HEADER]) {
    struct ovmc_header h;
    h.ok = 0;
    h.version = (uint16_t)((raw[4] << 8) | raw[5]);
    h.type = (uint16_t)((raw[6] << 8) | raw[7]);
    h.flags = (uint16_t)((raw[8] << 8) | raw[9]);
    h.length =
        ((uint32_t)raw[10] << 24) | ((uint32_t)raw[11] << 16) | ((uint32_t)raw[12] << 8) | raw[13];
    if (ovmc_memcmp(raw, OVMC_MAGIC, 4) != 0)
        return h;
    if (h.version != OVMC_VERSION)
        return h;
    if (h.flags != 0)
        return h;
    if (h.length > OVMC_MAX_PAYLOAD)
        return h;
    h.ok = 1;
    return h;
}

/* Walk a top-level map into pair spans. Returns the pair count, or -1 when the
 * body is not a well-formed map in the protocol subset. */
static long ovmc_walk_map(const uint8_t *body, size_t len, struct ovmc_pair *pairs, size_t cap,
                          uint64_t *correlation_id) {
    if (len == 0)
        return 0;
    struct ovmc_cur c = {body, len, 0, 1};
    uint8_t h0 = c.p[0];
    c.i = 1;
    long count = -1;
    if ((h0 >> 5) == 5) {
        int minor = h0 & 0x1f;
        if (minor < 24) {
            count = minor;
        } else if (minor <= 27) {
            count = (long)ovmc_get_be(&c, (size_t)1u << (minor - 24));
        }
        if (!c.ok)
            count = -1;
    }
    if (count < 0)
        return -1;

    size_t npairs = 0;
    *correlation_id = 0;
    while (count > 0 && c.ok) {
        count--;
        if (c.i >= c.n) {
            c.ok = 0;
            break;
        }
        size_t k0 = c.i;
        uint8_t kh = c.p[c.i++];
        if ((kh >> 5) != 3 || (kh & 0x1f) > 27) {
            c.ok = 0;
            break;
        }
        uint64_t klen = (kh & 0x1f) < 24 ? (uint64_t)(kh & 0x1f)
                                         : ovmc_get_be(&c, (size_t)1u << ((kh & 0x1f) - 24));
        if (!c.ok || c.n - c.i < klen) {
            c.ok = 0;
            break;
        }
        c.i += (size_t)klen;
        size_t k1 = c.i;
        size_t v0 = c.i;
        ovmc_parse_val(&c);
        size_t v1 = c.i;
        if (!c.ok || npairs >= cap) {
            c.ok = 0;
            break;
        }
        struct ovmc_pair *p = &pairs[npairs++];
        p->k0 = k0;
        p->k1 = k1;
        p->v0 = v0;
        p->v1 = v1;
        p->drop = 0;
        /* Lift the correlation id out as we go. */
        if (ovmc_key_is(p, body, "id"))
            (void)ovmc_uint_from(body + v0, v1 - v0, correlation_id);
    }
    if (!c.ok)
        return -1;
    return (long)npairs;
}

#endif /* OVMC_CODEC_H */
