#define main openvm_tools_main
#include "../guest/openvm-tools.c"
#undef main

#include <assert.h>
#include <sys/socket.h>

/* Drag and drop harness: drives handle_drag against a real file tree. The names
 * come from the host, and the destination belongs to the guest's user, so the
 * refusals and the no-follow behaviour matter as much as the copy. */

struct request {
    struct ovmc_out body;
    struct ovmc_pair pairs[8];
    size_t count;
};

static struct request *begin(struct request *r) {
    memset(r, 0, sizeof *r);
    r->body.ok = 1;
    ovmc_whdr(&r->body, 5, 0);
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

static void add_items(struct request *r, const char *const *names, size_t n) {
    key(r, "items");
    ovmc_whdr(&r->body, 4, n);
    for (size_t i = 0; i < n; i++)
        ovmc_wtext(&r->body, names[i]);
    end_value(r);
}

static uint8_t g_reply[1 << 16];
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
    handle_drag(s[0], r->body.b, r->pairs, r->count, 77);
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
    assert(((uint16_t)g_reply[6] << 8 | g_reply[7]) == T_DRAG_REPLY);
    g_reply_len = got;
}

static void op(const char *name) {
    static struct request r;
    begin(&r);
    add_text(&r, "op", name);
    dispatch(&r);
}

static void drop(const char *share, const char *const *items, size_t n) {
    static struct request r;
    begin(&r);
    add_text(&r, "op", "drop");
    add_text(&r, "share", share);
    add_items(&r, items, n);
    dispatch(&r);
}

/* Polls until the guest says done; the reply then stays in g_reply. */
static void wait_done(void) {
    for (int i = 0; i < 500; i++) {
        op("status");
        assert(!reply_has("no drop is running"));
        if (g_reply_len > 0 && reply_has("placed"))
            return;
        usleep(10000);
    }
    assert(!"the drop never finished");
}

static int exists(const char *relative) {
    char path[600];
    struct stat st;
    snprintf(path, sizeof path, "%s/Desktop/%s", OPENVM_DROP_HOME, relative);
    return lstat(path, &st) == 0;
}

static void test_enter_needs_a_session(void) {
    op("enter");
    assert(reply_has("no user is logged on"));
    char path[400];
    snprintf(path, sizeof path, "%s/%d", OPENVM_RUN_USER, (int)getuid());
    assert(mkdir(path, 0700) == 0);
    strncat(path, "/openvm-clipboard.env", sizeof path - strlen(path) - 1);
    FILE *f = fopen(path, "w");
    assert(f);
    fclose(f);
    op("enter");
    assert(!reply_has("error"));
    op("leave");
    assert(!reply_has("error"));
}

static void test_files_and_trees_land_on_the_desktop(void) {
    const char *items[] = {"note.txt", "tree", "Résumé final.pdf"};
    drop("dtest", items, 3);
    assert(!reply_has("error"));
    wait_done();
    assert(!reply_has("error"));
    assert(reply_has("note.txt") && reply_has("Résumé final.pdf"));
    /* note.txt 5 + tree/sub/deep.bin 7 + Résumé 3, and the link counts nothing */
    assert(exists("note.txt") && exists("tree/sub/deep.bin") && exists("Résumé final.pdf"));
    /* The link is copied as a link, never followed. */
    struct stat st;
    char path[600];
    snprintf(path, sizeof path, "%s/Desktop/tree/escape", OPENVM_DROP_HOME);
    assert(lstat(path, &st) == 0 && S_ISLNK(st.st_mode));
    assert(!exists(".openvm-drop-0"));
}

static void test_a_name_in_use_is_not_overwritten(void) {
    const char *items[] = {"note.txt"};
    drop("dtest", items, 1);
    wait_done();
    assert(reply_has("note (2).txt"));
    assert(exists("note.txt") && exists("note (2).txt"));
    drop("dtest", items, 1);
    wait_done();
    assert(reply_has("note (3).txt"));
}

/* An unreadable file fails cp part way: nothing of the copy may stay behind. */
static void test_a_failed_copy_leaves_nothing(void) {
    char path[600];
    snprintf(path, sizeof path, "%s/drops/dtest/tree2", OPENVM_FS_ROOT);
    assert(mkdir(path, 0755) == 0);
    strncat(path, "/secret", sizeof path - strlen(path) - 1);
    FILE *f = fopen(path, "w");
    assert(f);
    fputs("x", f);
    fclose(f);
    assert(chmod(path, 0) == 0);
    const char *items[] = {"tree2"};
    drop("dtest", items, 1);
    wait_done();
    chmod(path, 0644);
    assert(reply_has("could not copy"));
    char desktop[600];
    snprintf(desktop, sizeof desktop, "%s/Desktop", OPENVM_DROP_HOME);
    DIR *dir = opendir(desktop);
    assert(dir);
    for (struct dirent *e; (e = readdir(dir)) != NULL;)
        assert(strncmp(e->d_name, ".openvm-drop", 12) != 0 && strcmp(e->d_name, "tree2") != 0);
    closedir(dir);
}

static void test_a_missing_item_is_an_error(void) {
    const char *items[] = {"not-there"};
    drop("dtest", items, 1);
    wait_done();
    assert(reply_has("could not place"));
    op("status");
    assert(reply_has("no drop is running"));
}

static void test_hostile_names_are_refused(void) {
    const char *bad[] = {"../escape", "/etc/passwd", "a/b", "..", ".", "", "line\nbreak", "x\x7f"};
    for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
        const char *one[] = {bad[i]};
        drop("dtest", one, 1);
        assert(reply_has("valid item names"));
    }
    const char *ok[] = {"note.txt"};
    const char *shares[] = {"../..", "a b", "A", "x;reboot", ""};
    for (size_t i = 0; i < sizeof shares / sizeof shares[0]; i++) {
        drop(shares[i], ok, 1);
        assert(reply_has("no usable share"));
    }
    drop("gone", ok, 1); /* a valid share with nothing behind it */
    wait_done();
    assert(reply_has("could not place"));
}

static void test_send_needs_a_usable_path(void) {
    op("send");
    assert(reply_has("send has no usable path"));
}

static void test_unknown_op(void) {
    op("explode");
    assert(reply_has("drag op must be"));
}

int main(void) {
    test_send_needs_a_usable_path();
    test_enter_needs_a_session();
    test_files_and_trees_land_on_the_desktop();
    test_a_name_in_use_is_not_overwritten();
    if (getuid() != 0)
        test_a_failed_copy_leaves_nothing();
    test_a_missing_item_is_an_error();
    test_hostile_names_are_refused();
    test_unknown_op();
    puts("test-drag-agent: all checks passed");
    return 0;
}
