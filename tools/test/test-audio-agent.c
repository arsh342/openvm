#define main openvm_tools_main
#include "../guest/openvm-tools.c"
#undef main

#include <assert.h>
#include <sys/socket.h>

/* Audio harness: drives handle_audio against a fake /proc/asound tree. */

static uint8_t g_reply[8192];
static size_t g_reply_len;

static int reply_has(const char *needle) {
    size_t n = strlen(needle);
    for (size_t i = 0; i + n <= g_reply_len; i++)
        if (memcmp(g_reply + i, needle, n) == 0)
            return 1;
    return 0;
}

static void request(const char *op) {
    static struct ovmc_out body;
    struct ovmc_pair pair;
    memset(&body, 0, sizeof body);
    body.ok = 1;
    ovmc_whdr(&body, 5, 1);
    pair.k0 = body.n;
    ovmc_wtext(&body, "op");
    pair.k1 = body.n;
    pair.v0 = body.n;
    ovmc_wtext(&body, op);
    pair.v1 = body.n;
    pair.drop = 0;
    int s[2];
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, s) == 0);
    handle_audio(s[0], body.b, &pair, 1, 5);
    close(s[0]);
    ssize_t n = read(s[1], g_reply, sizeof g_reply);
    close(s[1]);
    assert(n >= OVMC_FRAME_HEADER);
    assert(((uint16_t)g_reply[6] << 8 | g_reply[7]) == T_AUDIO_REPLY);
    g_reply_len = (size_t)n;
}

int main(int argc, char **argv) {
    assert(argc == 2);
    if (strcmp(argv[1], "nocard") == 0) {
        request("status");
        assert(!reply_has("device"));
        request("test");
        assert(reply_has("no sound card"));
    } else {
        request("status");
        assert(reply_has("VirtIOSound"));
        assert(reply_has("running\xf5"));      /* true */
        assert(reply_has("rate\x19\xbb\x80")); /* 48000 as a two-byte CBOR uint */
        request("test");
        assert(!reply_has("error"));
        request("start"); /* the placeholder's ops are gone */
        assert(reply_has("audio op must be"));
    }
    puts("test-audio-agent: checks passed");
    return 0;
}
