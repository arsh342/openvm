#define main openvm_tools_main
#include "../guest/openvm-tools.c"
#undef main

#include <assert.h>
#include <sys/socket.h>

/* Printer harness: drives handle_printer against fake lpadmin/lpstat/lp (see
 * test-printer-agent.sh). A guest's spool and a host's names are both inputs a
 * bug here would trust, so the refusals matter as much as the happy path. */

struct request {
    struct ovmc_out body;
    struct ovmc_pair pairs[8];
    size_t count;
};

static struct request *begin(struct request *r) {
    memset(r, 0, sizeof *r);
    r->body.ok = 1;
    ovmc_whdr(&r->body, 5, 0); /* patched with the pair count at dispatch */
    return r;
}

static void key(struct request *r, const char *name) {
    struct ovmc_pair *p = &r->pairs[r->count];
    p->k0 = r->body.n;
    ovmc_wtext(&r->body, name);
    p->k1 = r->body.n;
    p->v0 = r->body.n;
}

static void end_value(struct request *r) {
    r->pairs[r->count].v1 = r->body.n;
    r->pairs[r->count].drop = 0;
    r->count++;
}

static void add_text(struct request *r, const char *name, const char *value) {
    key(r, name);
    ovmc_wtext(&r->body, value);
    end_value(r);
}

static void add_uint(struct request *r, const char *name, uint64_t value) {
    key(r, name);
    ovmc_wuint(&r->body, value);
    end_value(r);
}

static void add_names(struct request *r, const char *const *names, size_t n) {
    key(r, "printers");
    ovmc_whdr(&r->body, 4, n);
    for (size_t i = 0; i < n; i++)
        ovmc_wtext(&r->body, names[i]);
    end_value(r);
}

/* The raw reply body: the checks look for the bytes that must (not) be there. */
static uint8_t g_reply[1 << 21];
static size_t g_reply_len;

static int reply_has(const char *needle) {
    size_t n = strlen(needle);
    for (size_t i = 0; i + n <= g_reply_len; i++)
        if (memcmp(g_reply + i, needle, n) == 0)
            return 1;
    return 0;
}

static void dispatch(struct request *r) {
    r->body.b[0] = (uint8_t)(0xa0 | r->count);
    int s[2];
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, s) == 0);
    int buffer = 1 << 20;
    setsockopt(s[0], SOL_SOCKET, SO_SNDBUF, &buffer, sizeof buffer);
    handle_printer(s[0], r->body.b, r->pairs, r->count, 77);
    close(s[0]);
    size_t got = 0;
    for (;;) {
        ssize_t n = read(s[1], g_reply + got, sizeof g_reply - got);
        if (n <= 0)
            break;
        got += (size_t)n;
    }
    close(s[1]);
    assert(got >= OVMC_FRAME_HEADER);
    assert(memcmp(g_reply, OVMC_MAGIC, 4) == 0);
    assert(((uint16_t)g_reply[6] << 8 | g_reply[7]) == T_PRINTER_REPLY);
    g_reply_len = got;
}

static int calls_contain(const char *needle) {
    char line[512];
    FILE *f = fopen(getenv("OVM_TEST_CALLS"), "r");
    int found = 0;
    if (f == NULL)
        return 0;
    while (fgets(line, sizeof line, f))
        found |= strstr(line, needle) != NULL;
    fclose(f);
    return found;
}

static void reset_calls(void) {
    FILE *f = fopen(getenv("OVM_TEST_CALLS"), "w");
    assert(f);
    fclose(f);
}

static void spool_file(const char *name, const char *content) {
    char path[600];
    snprintf(path, sizeof path, "%s/%s", OPENVM_PRINT_SPOOL, name);
    FILE *f = fopen(path, "w");
    assert(f);
    fputs(content, f);
    fclose(f);
}

static void test_sync(void) {
    static struct request r;
    const char *names[] = {"Canon_MX920", "Brother.HL-2270"};

    reset_calls();
    begin(&r);
    add_text(&r, "op", "sync");
    add_names(&r, names, 2);
    add_text(&r, "default", "Canon_MX920");
    dispatch(&r);
    assert(!reply_has("error"));
    assert(reply_has("Brother.HL-2270"));
    assert(calls_contain("lpadmin -p Canon_MX920 -E -v openvm:/Canon_MX920 -P"));
    assert(calls_contain("lpadmin -p Brother.HL-2270 -E"));
    assert(calls_contain("lpadmin -d Canon_MX920"));
    /* The fake lpstat reports a queue named Stale that the host no longer has. */
    assert(calls_contain("lpadmin -x Stale"));
    assert(!calls_contain("lpadmin -x Canon_MX920"));
}

/* A name with shell meaning is refused whole: no queue is touched. */
static void test_sync_refuses_hostile_names(void) {
    static struct request r;
    const char *bad[][1] = {{"$(reboot)"}, {"a;b"}, {"a b"}, {"../x"}, {"-rf"}, {".hidden"}};
    for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
        reset_calls();
        begin(&r);
        add_text(&r, "op", "sync");
        add_names(&r, bad[i], 1);
        dispatch(&r);
        assert(reply_has("valid printer names"));
        assert(!calls_contain("lpadmin"));
    }
    reset_calls();
    begin(&r);
    const char *fine[] = {"ok"};
    add_text(&r, "op", "sync");
    add_names(&r, fine, 1);
    add_text(&r, "default", "x;reboot");
    dispatch(&r);
    assert(reply_has("invalid default"));
    assert(!calls_contain("lpadmin"));
}

static void test_list(void) {
    static struct request r;
    begin(&r);
    add_text(&r, "op", "list");
    dispatch(&r);
    assert(reply_has("Stale"));
    /* A queue on another device is the user's own, never ours to report. */
    assert(!reply_has("OfficeLaser"));
}

static void test_jobs_list_only_finished_regular_files(void) {
    static struct request r;
    char link_path[600];
    spool_file("Canon_MX920--7.pdf", "%PDF-1.7 hello");
    spool_file(".job-8-123", "partial");
    spool_file("notes.txt", "x");
    spool_file("nosplit.pdf", "x");
    snprintf(link_path, sizeof link_path, "%s/Canon_MX920--9.pdf", OPENVM_PRINT_SPOOL);
    assert(symlink("/etc/passwd", link_path) == 0);

    begin(&r);
    add_text(&r, "op", "jobs");
    dispatch(&r);
    assert(reply_has("Canon_MX920--7.pdf"));
    assert(reply_has("printer"));
    assert(!reply_has(".job-8"));
    assert(!reply_has("notes.txt"));
    assert(!reply_has("nosplit"));
    assert(!reply_has("Canon_MX920--9"));
}

static void test_fetch(void) {
    static struct request r;
    begin(&r);
    add_text(&r, "op", "fetch");
    add_text(&r, "job", "Canon_MX920--7.pdf");
    add_uint(&r, "offset", 5);
    add_uint(&r, "length", 3);
    dispatch(&r);
    assert(reply_has("1.7"));
    assert(!reply_has("%PDF"));

    const char *refused[] = {"../../etc/passwd", "/etc/passwd", "Canon_MX920--9.pdf"};
    for (size_t i = 0; i < 3; i++) {
        begin(&r);
        add_text(&r, "op", "fetch");
        add_text(&r, "job", refused[i]);
        add_uint(&r, "offset", 0);
        add_uint(&r, "length", 16);
        dispatch(&r);
        assert(reply_has("error"));
        assert(!reply_has("root:"));
    }

    begin(&r);
    add_text(&r, "op", "fetch");
    add_text(&r, "job", "Canon_MX920--7.pdf");
    add_uint(&r, "offset", 0);
    add_uint(&r, "length", PRINT_CHUNK_MAX + 1);
    dispatch(&r);
    assert(reply_has("bounded length"));
}

static void test_done(void) {
    static struct request r;
    char path[600];
    snprintf(path, sizeof path, "%s/Canon_MX920--7.pdf", OPENVM_PRINT_SPOOL);

    begin(&r);
    add_text(&r, "op", "done");
    add_text(&r, "job", "../outside.pdf");
    dispatch(&r);
    assert(reply_has("error"));
    assert(access(path, F_OK) == 0);

    for (int twice = 0; twice < 2; twice++) { /* removing a removed job is success */
        begin(&r);
        add_text(&r, "op", "done");
        add_text(&r, "job", "Canon_MX920--7.pdf");
        dispatch(&r);
        assert(!reply_has("error"));
    }
    assert(access(path, F_OK) != 0);
}

static void test_page(void) {
    static struct request r;
    reset_calls();
    begin(&r);
    add_text(&r, "op", "test");
    add_text(&r, "name", "Canon_MX920");
    dispatch(&r);
    assert(!reply_has("error"));
    assert(calls_contain("lp -d Canon_MX920"));

    reset_calls();
    begin(&r);
    add_text(&r, "op", "test");
    add_text(&r, "name", "a;reboot");
    dispatch(&r);
    assert(reply_has("error"));
    assert(!calls_contain("lp -d"));
}

static void test_unknown_op(void) {
    static struct request r;
    begin(&r);
    add_text(&r, "op", "print");
    dispatch(&r);
    assert(reply_has("printer op must be"));
}

int main(void) {
    test_sync();
    test_sync_refuses_hostile_names();
    test_list();
    test_jobs_list_only_finished_regular_files();
    test_fetch();
    test_done();
    test_page();
    test_unknown_op();
    puts("test-printer-agent: all checks passed");
    return 0;
}
