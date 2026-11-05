#!/bin/sh
# test-windows-agent.sh — checks the Windows guest agent without Windows.
#
# The agent cannot run on macOS (no vsock provider), but three things can and
# must be checked here:
#
#   1. The file compiles as C99 with no warnings, in syntax-check mode. That
#      catches codec and handler regressions on every commit.
#
#   1b. The real Win32 build cross-compiles with -Werror (when zig is present).
#
#   2. The shared codec (tools/guest/ovmc_codec.h) round-trips the frames and
#      messages the host actually sends. This is the part where a silent
#      disagreement between the two agents would be most expensive, so it gets
#      a real executable test rather than a compile check.
#
# The host-side conformance suite (tools/test/conformance.sh) proves the Swift codec
# against golden bytes. This proves the C codec the Windows agent uses against
# the same wire rules.
set -eu

cd "$(dirname "$0")/../.."

CC=${CC:-clang}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "test-windows-agent: compiling the agent (syntax check)"
# -Werror: the agent is new code, so warnings are not allowed to accumulate.
$CC -std=c99 -Wall -Wextra -Werror -Wno-unused-function -Wno-unused-variable \
    -DOPENVM_SYNTAX_CHECK -c -o "$WORK/agent.o" tools/guest/openvm-tools-win.c
echo "test-windows-agent: agent compiles clean"

# The agent has two bodies: the syntax-check stubs and the real Win32 path. The
# first pass above only proves the stubs compile. The real path is checked by
# cross-compiling it against the actual Windows headers (mingw-w64, via zig),
# which is the same build tools/build/mk-windows-media.sh puts on the guest.
if command -v zig >/dev/null; then
    echo "test-windows-agent: cross-compiling the real agent (aarch64-windows)"
    sh tools/build/build-windows-agent.sh "$WORK/win" >/dev/null
    echo "test-windows-agent: real Win32 path builds clean"
else
    echo "test-windows-agent: zig not installed; skipped the real Win32 build (brew install zig)"
fi

echo "test-windows-agent: building the codec test"
cat > "$WORK/codec_test.c" <<'EOF'
#include <stdio.h>
#include "ovmc_codec.h"

static int failures = 0;

static void check(int cond, const char *what) {
    if (!cond) {
        failures++;
        printf("FAIL %s\n", what);
    }
}

/* A frame header must round-trip through the parser with the same fields. */
static void test_header_roundtrip(void) {
    uint8_t hdr[OVMC_FRAME_HEADER];
    check(ovmc_frame_header(hdr, T_ECHO_REQUEST, 42), "header encodes");
    struct ovmc_header h = ovmc_parse_header(hdr);
    check(h.ok, "header parses");
    check(h.type == T_ECHO_REQUEST, "type survives");
    check(h.length == 42, "length survives");
    check(h.version == OVMC_VERSION, "version is 1");
    check(h.flags == 0, "flags are 0");
}

/* Every receiver stop rule in docs/guest-protocol.md must reject. */
static void test_stop_rules(void) {
    uint8_t hdr[OVMC_FRAME_HEADER];

    ovmc_frame_header(hdr, T_ECHO_REQUEST, 4);
    hdr[0] = 'X';
    check(!ovmc_parse_header(hdr).ok, "bad magic stops");

    ovmc_frame_header(hdr, T_ECHO_REQUEST, 4);
    hdr[5] = 2;
    check(!ovmc_parse_header(hdr).ok, "bad version stops");

    ovmc_frame_header(hdr, T_ECHO_REQUEST, 4);
    hdr[8] = 1;
    check(!ovmc_parse_header(hdr).ok, "nonzero flags stop");

    /* length above the 1 MiB cap */
    ovmc_frame_header(hdr, T_ECHO_REQUEST, 4);
    hdr[10] = 0x00; hdr[11] = 0x20; hdr[12] = 0x00; hdr[13] = 0x00;
    check(!ovmc_parse_header(hdr).ok, "oversized length stops");

    /* Exactly the cap is allowed. */
    ovmc_frame_header(hdr, T_ECHO_REQUEST, OVMC_MAX_PAYLOAD);
    check(ovmc_parse_header(hdr).ok, "length at the cap is accepted");
}

/* A hello body as the host encodes it: {product, version, id}. */
static void test_walk_map(void) {
    struct ovmc_out w;
    ovmc_out_init(&w);
    ovmc_whdr(&w, 5, 3);
    ovmc_wtext(&w, "product");
    ovmc_wtext(&w, "openvm");
    ovmc_wtext(&w, "version");
    ovmc_wuint(&w, 1);
    ovmc_wtext(&w, "id");
    ovmc_wuint(&w, 7);
    check(w.ok, "hello body encodes");

    struct ovmc_pair pairs[OVMC_MAX_PAIRS];
    uint64_t cid = 0;
    long n = ovmc_walk_map(w.b, w.n, pairs, OVMC_MAX_PAIRS, &cid);
    check(n == 3, "three pairs walked");
    check(cid == 7, "correlation id lifted");

    const struct ovmc_pair *p = ovmc_find(w.b, pairs, (size_t)n, "product");
    check(p != NULL, "product key found");
    if (p) {
        const uint8_t *t = NULL;
        size_t len = 0;
        check(ovmc_text_span(w.b + p->v0, p->v1 - p->v0, &t, &len), "product is text");
        check(len == 6 && ovmc_memcmp(t, "openvm", 6) == 0, "product value is openvm");
    }

    p = ovmc_find(w.b, pairs, (size_t)n, "version");
    check(p != NULL, "version key found");
    if (p) {
        uint64_t v = 0;
        check(ovmc_uint_from(w.b + p->v0, p->v1 - p->v0, &v), "version is uint");
        check(v == 1, "version value is 1");
    }
}

/* A malformed body must be rejected, not guessed at. */
static void test_malformed(void) {
    struct ovmc_pair pairs[OVMC_MAX_PAIRS];
    uint64_t cid = 0;

    /* Not a map: a text string at the top level. */
    struct ovmc_out w;
    ovmc_out_init(&w);
    ovmc_wtext(&w, "nope");
    check(ovmc_walk_map(w.b, w.n, pairs, OVMC_MAX_PAIRS, &cid) < 0, "non-map rejected");

    /* Truncated map: claims two pairs, carries one. */
    ovmc_out_init(&w);
    ovmc_whdr(&w, 5, 2);
    ovmc_wtext(&w, "id");
    ovmc_wuint(&w, 1);
    check(ovmc_walk_map(w.b, w.n, pairs, OVMC_MAX_PAIRS, &cid) < 0, "truncated map rejected");

    /* Indefinite-length item is outside the subset. */
    uint8_t bad[] = {0xbf, 0xff};
    check(ovmc_walk_map(bad, sizeof bad, pairs, OVMC_MAX_PAIRS, &cid) < 0,
          "indefinite length rejected");
}

/* The echo reply must carry the request body back with the id re-appended last,
 * which is the rule the host's decoder relies on. */
static void test_echo_shape(void) {
    struct ovmc_out w;
    ovmc_out_init(&w);
    ovmc_whdr(&w, 5, 2);
    ovmc_wtext(&w, "k");
    ovmc_wtext(&w, "v");
    ovmc_wtext(&w, "id");
    ovmc_wuint(&w, 3);

    struct ovmc_pair pairs[OVMC_MAX_PAIRS];
    uint64_t cid = 0;
    long n = ovmc_walk_map(w.b, w.n, pairs, OVMC_MAX_PAIRS, &cid);
    check(n == 2, "echo body has two pairs");
    check(cid == 3, "echo id is 3");
    /* The last pair must be the id: that is what "appended last" means. */
    check(ovmc_key_is(&pairs[n - 1], w.b, "id"), "id is the last pair");
}

/* The later message types must be in the catalogue and must not collide. */
static void test_catalogue_extension(void) {
    check(T_DRAG_REQUEST == 18 && T_DRAG_REPLY == 19, "drag ids");
    check(T_PRINTER_REQUEST == 20 && T_PRINTER_REPLY == 21, "printer ids");
    check(T_AUDIO_REQUEST == 22 && T_AUDIO_REPLY == 23, "audio ids");
    check(T_DISPLAY_REQUEST == 24 && T_DISPLAY_REPLY == 25, "display ids");
    /* Append-only: every id from 1..25 is distinct. */
    int seen[32] = {0};
    int ids[] = {T_HELLO, T_HELLO_REPLY, T_ECHO_REQUEST, T_ECHO_REPLY, T_ERROR,
                 T_CLIPBOARD_REQUEST, T_CLIPBOARD_REPLY, T_FILE_REQUEST, T_FILE_REPLY,
                 T_TIMESYNC_REQUEST, T_TIMESYNC_REPLY, T_SHARED_REQUEST, T_SHARED_REPLY,
                 T_SUSPEND_REQUEST, T_SUSPEND_REPLY, T_DRAG_REQUEST, T_DRAG_REPLY,
                 T_PRINTER_REQUEST, T_PRINTER_REPLY, T_AUDIO_REQUEST, T_AUDIO_REPLY,
                 T_DISPLAY_REQUEST, T_DISPLAY_REPLY};
    int dup = 0;
    for (size_t i = 0; i < sizeof ids / sizeof ids[0]; i++) {
        if (ids[i] < 0 || ids[i] >= 32) { dup = 1; break; }
        if (seen[ids[i]]) { dup = 1; break; }
        seen[ids[i]] = 1;
    }
    check(!dup, "catalogue ids are distinct");
}

/* The parser is the only thing between a frame and the handlers. */
static int walks(const uint8_t *body, size_t len) {
    static struct ovmc_pair pairs[8];
    uint64_t cid = 0;
    return ovmc_walk_map(body, len, pairs, 8, &cid) >= 0;
}

static void test_parser_rules(void) {
    const uint8_t good[] = {0xa1, 0x61, 'a', 0xa1, 0x61, 'b', 0xf5};
    check(walks(good, sizeof good), "nested text-keyed map parses");
    const uint8_t uint_key[] = {0xa1, 0x61, 'a', 0xa1, 0x01, 0x02};
    check(!walks(uint_key, sizeof uint_key), "a nested map key must be text");
    const uint8_t simple[] = {0xa1, 0x61, 'a', 0xe0};
    check(!walks(simple, sizeof simple), "an unassigned simple value is refused");
    const uint8_t null_value[] = {0xa1, 0x61, 'a', 0xf6};
    check(walks(null_value, sizeof null_value), "null is allowed");
    const uint8_t negative[] = {0xa1, 0x61, 'a', 0x20};
    check(walks(negative, sizeof negative), "a negative integer is in the subset");
    /* A map claiming 2^63 entries: arg * 2 would wrap to 0 and pass. */
    const uint8_t huge[] = {0xa1, 0x61, 'a', 0xbb, 0x80, 0, 0, 0, 0, 0, 0, 0};
    check(!walks(huge, sizeof huge), "a map longer than its bytes is refused");
    const uint8_t tag[] = {0xa1, 0x61, 'a', 0xc0, 0x01};
    check(!walks(tag, sizeof tag), "a tag is refused");
}

/* A display request body as the host encodes it: {width, height, id}. */
static void test_display_body(void) {
    struct ovmc_out w;
    ovmc_out_init(&w);
    ovmc_whdr(&w, 5, 3);
    ovmc_wtext(&w, "width");
    ovmc_wuint(&w, 2560);
    ovmc_wtext(&w, "height");
    ovmc_wuint(&w, 1440);
    ovmc_wtext(&w, "id");
    ovmc_wuint(&w, 11);
    check(w.ok, "display body encodes");

    struct ovmc_pair pairs[OVMC_MAX_PAIRS];
    uint64_t cid = 0;
    long n = ovmc_walk_map(w.b, w.n, pairs, OVMC_MAX_PAIRS, &cid);
    check(n == 3, "display body has three pairs");
    check(cid == 11, "display id lifted");

    const struct ovmc_pair *p = ovmc_find(w.b, pairs, (size_t)n, "width");
    uint64_t v = 0;
    check(p != NULL && ovmc_uint_from(w.b + p->v0, p->v1 - p->v0, &v), "width is uint");
    check(v == 2560, "width value");
}

static int item_ok(const char *name) {
    return ovmc_valid_windows_item((const uint8_t *)name, ovmc_strlen(name));
}

/* Names a host can drop that Windows must not be handed. */
static void test_windows_item_names(void) {
    const char *good[] = {"a.txt", "R\xc3\xa9sum\xc3\xa9 final (2).pdf", ".hidden", "console.txt",
                          "COM.txt", "nullable", "LPT", "com10"};
    const char *bad[] = {"", "a/b", "a\\b", "..\\x", "C:evil", "file.txt:stream", "a*", "a?", "a\"b",
                         "a<b", "a>b", "a|b", "dot.", "space ", "..", ".", "NUL", "nul.txt", "CON",
                         "Aux.log", "PRN", "COM1", "com9.txt", "LPT3", "line\nbreak", "del\x7f"};
    for (size_t i = 0; i < sizeof good / sizeof good[0]; i++)
        check(item_ok(good[i]), good[i]);
    for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++)
        check(!item_ok(bad[i]), bad[i]);
}

int main(void) {
    test_windows_item_names();
    test_catalogue_extension();
    test_display_body();
    test_parser_rules();
    test_header_roundtrip();
    test_stop_rules();
    test_walk_map();
    test_malformed();
    test_echo_shape();
    if (failures) {
        printf("test-windows-agent: %d failure(s)\n", failures);
        return 1;
    }
    printf("test-windows-agent: codec ok\n");
    return 0;
}
EOF

$CC -std=c99 -Wall -Wextra -Werror -Wno-unused-function -I tools/guest \
    -o "$WORK/codec_test" "$WORK/codec_test.c"
"$WORK/codec_test"

echo "test-windows-agent: all checks passed"
