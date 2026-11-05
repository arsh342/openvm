/*
 * openvm-tools — the openvm guest agent.
 *
 * Speaks the OVMC protocol (docs/guest-protocol.md) over the openvm channel port:
 *   frame: 4-byte magic "OVMC" | version u16 | type u16 | flags u16 | length u32 | CBOR body
 *   (big-endian header). CBOR subset: maps (major 5) with text keys, text (3),
 *   unsigned ints (0), byte strings (2), arrays (4), true/false/null (7).
 *   No negatives, floats, tags or indefinite lengths.
 *
 * This agent is the ANSWERING side of the channel — it mirrors openvm-mockguest:
 *   hello        -> helloReply {accepted: true, version: 1}
 *   echoRequest  -> echoReply   {same body pairs minus "id", then "id" re-appended last}
 *   reply types  -> error {errno: 1 unknownType}
 *   unparseable  -> error {errno: 2 badPayload}, correlation id 0
 * A first frame-rule violation (magic/version/flags/size) closes the
 * connection; no resync. Malformed BODIES answer with the error envelope and
 * the loop continues.
 *
 * Build (inside the alpine guest): cc -O2 -o openvm-tools openvm-tools.c
 * Usage: openvm-tools   (listens on the vsock channel port, one connection at a time)
 */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <ftw.h>
#include <grp.h>
#include <pwd.h>
#include <stdint.h>
#include <stdio.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "ovmc_codec.h"

#ifdef __APPLE__
/* host syntax-check shim: the agent really builds in the alpine guest; clang
   -fsyntax-only runs on macOS, where the Linux vsock UAPI does not exist. */
#define AF_VSOCK 40
#define VMADDR_CID_ANY 0xffffffffu
struct sockaddr_vm {
    sa_family_t svm_family;
    unsigned short svm_reserved1;
    uint32_t svm_port;
    uint32_t svm_cid;
    uint8_t svm_zero[4];
};
#else
#include <linux/vm_sockets.h> /* sockaddr_vm, AF_VSOCK, VMADDR_CID_ANY */
#endif

#ifndef OPENVM_POWEROFF
#define OPENVM_POWEROFF "poweroff"
#endif
#ifndef OPENVM_SHARE_PARENT
#define OPENVM_SHARE_PARENT "/tmp"
#endif
#ifndef OPENVM_SHARE_NAME
#define OPENVM_SHARE_NAME "openvm-share"
#endif
#ifndef OPENVM_TZINFO_DIR
#define OPENVM_TZINFO_DIR "/usr/share/zoneinfo"
#endif
#ifndef OPENVM_LOCALTIME_PATH
#define OPENVM_LOCALTIME_PATH "/etc/localtime"
#endif

enum { FILE_CHUNK_MAX = 64 * 1024 };
#define FILE_SIZE_MAX (1ULL << 30)

static void write_reply(int fd, uint16_t type, const uint8_t *body, size_t blen);

static int pair_key_is(const uint8_t *body, const struct ovmc_pair *pair, const char *key) {
    const uint8_t *value;
    size_t length;
    size_t key_length = strlen(key);
    return ovmc_text_span(body + pair->k0, pair->k1 - pair->k0, &value, &length) &&
           length == key_length && memcmp(value, key, length) == 0;
}

static const struct ovmc_pair *find_pair(const uint8_t *body, const struct ovmc_pair *pairs,
                                         size_t count, const char *key) {
    for (size_t i = 0; i < count; i++)
        if (!pairs[i].drop && pair_key_is(body, &pairs[i], key))
            return &pairs[i];
    return NULL;
}

#include "linux/clipboard.c"
#include "linux/files.c"
#include "linux/frames.c"
#include "linux/timesync.c"
#include "linux/shares.c"
#include "linux/suspend.c"
#include "linux/shares-request.c"
#include "linux/drag.c"
#include "linux/printers.c"
#include "linux/audio.c"
#include "linux/display.c"

static void serve(int fd, uint8_t *ring) {
    uint8_t head[OVMC_FRAME_HEADER];
    for (;;) {
        size_t have = 0;
        while (have < OVMC_FRAME_HEADER) {
            ssize_t k = read(fd, head + have, OVMC_FRAME_HEADER - have);
            if (k <= 0) {
                if (k < 0 && errno == EINTR)
                    continue;
                return;
            }
            have += (size_t)k;
        }
        if (memcmp(head, OVMC_MAGIC, 4) != 0)
            return;
        uint16_t ver = (uint16_t)((head[4] << 8) | head[5]);
        uint16_t type = (uint16_t)((head[6] << 8) | head[7]);
        uint16_t flags = (uint16_t)((head[8] << 8) | head[9]);
        uint32_t len = ((uint32_t)head[10] << 24) | ((uint32_t)head[11] << 16) |
                       ((uint32_t)head[12] << 8) | head[13];
        if (ver != 1 || flags != 0 || len > OVMC_MAX_PAYLOAD)
            return; /* receiver stop rules: close, no resync */
        uint8_t *body = (uint8_t *)ring;
        size_t have2 = 0;
        while (have2 < len) {
            ssize_t k = read(fd, body + have2, len - have2);
            if (k <= 0) {
                if (k < 0 && errno == EINTR)
                    continue;
                return;
            }
            have2 += (size_t)k;
        }

        /* top-level map walk: collect pair spans, lift the id out */
        struct ovmc_pair pairs[OVMC_MAX_PAIRS];
        size_t npairs = 0;
        uint64_t cid = 0;
        struct ovmc_cur c = {body, len, 0, 1};
        if (len > 0) {
            uint8_t h0 = c.p[0];
            c.i = 1;
            int64_t count = -1;
            if ((h0 >> 5) == 5) {
                int minor = h0 & 0x1f;
                if (minor < 24)
                    count = minor;
                else if (minor <= 27)
                    count =
                        (int64_t)ovmc_get_be(&c, 1u << (minor - 24)); /* header already consumed */
                if (!c.ok)
                    count = -1;
            }
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
                uint64_t klen =
                    (uint64_t)((kh & 0x1f) < 24 ? kh & 0x1f
                                                : ovmc_get_be(&c, 1u << ((kh & 0x1f) - 24)));
                if (!c.ok || c.n - c.i < klen) {
                    c.ok = 0;
                    break;
                }
                const uint8_t *kc = c.p + c.i;
                size_t kcontent = (size_t)klen;
                c.i += klen;
                size_t k1 = c.i;
                size_t v0 = c.i;
                ovmc_parse_val(&c);
                size_t v1 = c.i;
                if (!c.ok || npairs >= OVMC_MAX_PAIRS) {
                    if (c.ok)
                        c.ok = 0;
                    break;
                }
                struct ovmc_pair *p = &pairs[npairs++];
                p->k0 = k0;
                p->k1 = k1;
                p->v0 = v0;
                p->v1 = v1;
                p->drop = 0;
                if (kcontent == 2 && kc[0] == 'i' && kc[1] == 'd' &&
                    ovmc_uint_from(body + v0, v1 - v0, &cid)) {
                    p->drop = 1;
                }
            }
            if (count != 0 || c.i != len)
                c.ok = 0; /* unbalanced count or trailing junk */
        } else
            c.ok = 0;

        if (!c.ok) {
            emit_error(fd, 0, OVMC_ERR_BAD_PAYLOAD, "unparseable payload");
            continue; /* a bad body answers with an error and keeps going */
        }

        switch (type) {
        case T_HELLO: {
            struct ovmc_out w = {.n = 0, .ok = 1};
            ovmc_whdr(&w, 5, 3);
            ovmc_wtext(&w, "accepted");
            ovmc_wbool(&w, 1);
            ovmc_wtext(&w, "version");
            ovmc_wuint(&w, 1);
            ovmc_wtext(&w, "id");
            ovmc_wuint(&w, cid);
            if (w.ok)
                write_reply(fd, T_HELLO_REPLY, w.b, w.n);
            break;
        }
        case T_ECHO_REQUEST: {
            struct ovmc_out w = {.n = 0, .ok = 1};
            size_t kept = 0;
            for (size_t i = 0; i < npairs; i++)
                if (!pairs[i].drop)
                    kept++;
            ovmc_whdr(&w, 5, kept + 1); /* id re-appended last */
            for (size_t i = 0; i < npairs && w.ok; i++) {
                if (pairs[i].drop)
                    continue;
                for (size_t k = pairs[i].k0; k < pairs[i].k1 && w.ok; k++)
                    ovmc_w8(&w, body[k]);
                for (size_t k = pairs[i].v0; k < pairs[i].v1 && w.ok; k++)
                    ovmc_w8(&w, body[k]);
            }
            if (w.ok) {
                ovmc_wtext(&w, "id");
                ovmc_wuint(&w, cid);
            }
            if (!w.ok)
                emit_error(fd, cid, OVMC_ERR_BAD_PAYLOAD, "echo body too large");
            else
                write_reply(fd, T_ECHO_REPLY, w.b, w.n);
            break;
        }
        case T_CLIPBOARD_REQUEST:
            handle_clipboard(fd, body, pairs, npairs, cid);
            break;
        case T_FILE_REQUEST:
            handle_file(fd, body, pairs, npairs, cid);
            break;
        case T_TIMESYNC_REQUEST:
            handle_timesync(fd, body, pairs, npairs, cid);
            break;
        case T_SHARED_REQUEST:
            handle_shared(fd, body, pairs, npairs, cid);
            break;
        case T_SUSPEND_REQUEST:
            handle_suspend(fd, body, pairs, npairs, cid);
            break;
        case T_DRAG_REQUEST:
            handle_drag(fd, body, pairs, npairs, cid);
            break;
        case T_PRINTER_REQUEST:
            handle_printer(fd, body, pairs, npairs, cid);
            break;
        case T_AUDIO_REQUEST:
            handle_audio(fd, body, pairs, npairs, cid);
            break;
        case T_DISPLAY_REQUEST:
            handle_display(fd, body, pairs, npairs, cid);
            break;
        case T_HELLO_REPLY:
        case T_ECHO_REPLY:
        case T_CLIPBOARD_REPLY:
        case T_FILE_REPLY:
        case T_TIMESYNC_REPLY:
        case T_SHARED_REPLY:
        case T_SUSPEND_REPLY:
            emit_error(fd, cid, OVMC_ERR_UNKNOWN_TYPE, "reply type on the request channel");
            break;
        default:
            emit_error(fd, cid, OVMC_ERR_UNKNOWN_TYPE, "unknown type");
            break;
        }
    }
}

int main(void) {
    static uint8_t ring[OVMC_MAX_PAYLOAD]; /* one frame body at a time */
    signal(SIGPIPE, SIG_IGN);              /* a disconnected host must not kill the agent */
    /* A service inherits whatever PATH its supervisor has; the handlers run
     * admin tools (lpadmin lives in /usr/sbin). */
    setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", 1);
    for (;;) {
        int lfd = socket(AF_VSOCK, SOCK_STREAM, 0);
        if (lfd < 0) {
            fprintf(stderr, "openvm-tools: AF_VSOCK socket failed: %s\n", strerror(errno));
            sleep(1); /* module race behind the rc script's modprobe */
            continue;
        }
        struct sockaddr_vm sa;
        memset(&sa, 0, sizeof sa);
        sa.svm_family = AF_VSOCK;
        sa.svm_cid = VMADDR_CID_ANY;
        sa.svm_port = OVMC_VSOCK_PORT;
        if (bind(lfd, (struct sockaddr *)&sa, sizeof sa) < 0) {
            fprintf(stderr, "openvm-tools: bind on vsock port %d failed: %s\n", OVMC_VSOCK_PORT,
                    strerror(errno));
            close(lfd);
            sleep(1);
            continue;
        }
        /* backlog 8: the host opens a new connection per exchange and may
           connect while we are still serving the previous one; a queue of one
           makes the kernel refuse the pending connection instead. */
        if (listen(lfd, 8) < 0) {
            fprintf(stderr, "openvm-tools: listen on vsock port %d failed: %s\n", OVMC_VSOCK_PORT,
                    strerror(errno));
            close(lfd);
            sleep(1);
            continue;
        }
        fprintf(stderr, "openvm-tools: listening on vsock port %d\n", OVMC_VSOCK_PORT);
        for (;;) {
            int fd = accept(lfd, NULL, NULL);
            if (fd < 0) {
                if (errno == EINTR)
                    continue;
                fprintf(stderr, "openvm-tools: accept failed: %s\n", strerror(errno));
                break; /* listener died; rebuild it */
            }
            serve(fd, ring);
            close(fd);
        }
        close(lfd);
    }
}
