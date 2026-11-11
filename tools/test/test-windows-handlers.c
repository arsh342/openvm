#define main openvm_win_main
#include "../guest/openvm-tools-win.c"
#undef main

#include <assert.h>
#include <stdio.h>
#include <string.h>

/* Hostile input to the Windows agent's drop parser. The item names come from the host, but the agent
 * does not trust them: a name is put into a path on the user's Desktop, so everything that could leave
 * the folder, name a device or break the one-name-per-line list to the helper must be refused, and a
 * malformed array must never read past its span. */

static size_t array_of(uint8_t *buf, const char *const *names, size_t n) {
    struct ovmc_out w;
    ovmc_out_init(&w);
    ovmc_whdr(&w, 4, n);
    for (size_t i = 0; i < n; i++)
        ovmc_wtext(&w, names[i]);
    assert(w.ok);
    memcpy(buf, w.b, w.n);
    return w.n;
}

static size_t parse(const char *const *names, size_t n, char *out, size_t cap) {
    static uint8_t buf[OVMC_MAX_PAYLOAD];
    size_t len = array_of(buf, names, n);
    return drop_item_lines(buf, len, out, cap);
}

static void test_good(void) {
    char out[1024];
    const char *names[] = {"a.txt", "R\xc3\xa9sum\xc3\xa9 (2).pdf"};
    size_t used = parse(names, 2, out, sizeof out);
    assert(used == strlen("a.txt\nR\xc3\xa9sum\xc3\xa9 (2).pdf\n"));
    assert(memcmp(out, "a.txt\n", 6) == 0);
}

static void test_bad_names(void) {
    char out[1024];
    const char *bad[] = {"..\\x",   "a/b",         "C:evil", "f.txt:stream", "NUL",
                         "con.txt", "line\nbreak", "",       "dot.",         "tab\t"};
    for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
        const char *one[] = {bad[i]};
        assert(parse(one, 1, out, sizeof out) == 0);
        /* One bad name spoils the whole set, even after good ones. */
        const char *two[] = {"good.txt", bad[i]};
        assert(parse(two, 2, out, sizeof out) == 0);
    }
}

static void test_counts_and_room(void) {
    char out[DROP_ITEMS_MAX * DROP_NAME_MAX];
    const char *many[DROP_ITEMS_MAX + 1];
    char names[DROP_ITEMS_MAX + 1][8];
    for (size_t i = 0; i <= DROP_ITEMS_MAX; i++) {
        snprintf(names[i], sizeof names[i], "f%zu", i);
        many[i] = names[i];
    }
    assert(parse(many, DROP_ITEMS_MAX, out, sizeof out) > 0);
    assert(parse(many, DROP_ITEMS_MAX + 1, out, sizeof out) == 0);
    assert(parse(many, 0, out, sizeof out) == 0);
    /* No room for the list: refused, not truncated. */
    const char *one[] = {"abcdef"};
    assert(parse(one, 1, out, 6) == 0);
    assert(parse(one, 1, out, 7) == 7);
}

static void test_malformed_cbor(void) {
    char out[256];
    uint8_t buf[OVMC_MAX_PAYLOAD];
    /* not an array */
    uint8_t text[] = {0x61, 'a'};
    assert(drop_item_lines(text, sizeof text, out, sizeof out) == 0);
    /* an empty span */
    assert(drop_item_lines(buf, 0, out, sizeof out) == 0);
    /* an array that promises more items than it holds */
    uint8_t short_list[] = {0x82, 0x61, 'a'};
    assert(drop_item_lines(short_list, sizeof short_list, out, sizeof out) == 0);
    /* an item whose text claims more bytes than the span has */
    uint8_t long_text[] = {0x81, 0x78, 0xff, 'a'};
    assert(drop_item_lines(long_text, sizeof long_text, out, sizeof out) == 0);
    /* trailing bytes after the array */
    uint8_t trailing[] = {0x81, 0x61, 'a', 0x00};
    assert(drop_item_lines(trailing, sizeof trailing, out, sizeof out) == 0);
    /* an item that is not text */
    uint8_t number[] = {0x81, 0x05};
    assert(drop_item_lines(number, sizeof number, out, sizeof out) == 0);
    /* a nested array where a name belongs */
    uint8_t nested[] = {0x81, 0x81, 0x61, 'a'};
    assert(drop_item_lines(nested, sizeof nested, out, sizeof out) == 0);
    /* an indefinite-length array */
    uint8_t indefinite[] = {0x9f, 0x61, 'a', 0xff};
    assert(drop_item_lines(indefinite, sizeof indefinite, out, sizeof out) == 0);
    /* a one-byte count with no byte */
    uint8_t cut[] = {0x98};
    assert(drop_item_lines(cut, sizeof cut, out, sizeof out) == 0);
    /* every prefix of a good array is refused */
    const char *names[] = {"a.txt", "b.txt"};
    size_t len = array_of(buf, names, 2);
    for (size_t n = 0; n < len; n++)
        assert(drop_item_lines(buf, n, out, sizeof out) == 0);
    assert(drop_item_lines(buf, len, out, sizeof out) > 0);
}

/* Which displays the agent keeps. Windows drives openVM's boot frame buffer through the Basic Display
 * Driver as a second, invisible display (docs/evidence/windows-second-display-2026-11-11.md). The agent
 * switches that off, but only while the virtio display is active, so Windows' fallback stays if viogpudo
 * fails. */
static void test_virtio_adapter_names(void) {
    assert(display_is_virtio_adapter(
        "\\\\?\\PCI#VEN_1AF4&DEV_1050&SUBSYS_00501AF4&REV_01#3&11583659&0&48#{5b45201d}"));
    assert(
        display_is_virtio_adapter("\\\\?\\pci#ven_1af4&dev_1050&subsys_00501af4&rev_01#3&1#{x}"));
    assert(!display_is_virtio_adapter("\\\\?\\ROOT#BasicDisplay#0000#{5b45201d}"));
    assert(!display_is_virtio_adapter(
        "\\\\?\\PCI#VEN_1AF4&DEV_1041#3&1#{x}")); /* virtio-net, not the GPU */
    assert(!display_is_virtio_adapter(""));
    assert(!display_is_virtio_adapter(NULL));
}

static void test_which_displays_to_keep(void) {
    int keep[4];
    /* Basic Display beside the virtio display: keep only the virtio one. */
    int both[] = {0, 1};
    assert(display_choose_kept(both, 2, keep) == 1);
    assert(keep[0] == 0 && keep[1] == 1);
    /* virtio first in the list makes no difference */
    int other_order[] = {1, 0};
    assert(display_choose_kept(other_order, 2, keep) == 1);
    assert(keep[0] == 1 && keep[1] == 0);
    /* viogpudo failed: only the Basic Display is active, so nothing changes */
    int fallback[] = {0};
    assert(display_choose_kept(fallback, 1, keep) == 0);
    /* already only the virtio display: nothing to change */
    int alone[] = {1};
    assert(display_choose_kept(alone, 1, keep) == 0);
    /* nothing active */
    assert(display_choose_kept(NULL, 0, keep) == 0);
    /* two virtio paths and one other: both virtio paths stay */
    int three[] = {1, 0, 1};
    assert(display_choose_kept(three, 3, keep) == 2);
    assert(keep[0] == 1 && keep[1] == 0 && keep[2] == 1);
}

int main(void) {
    test_virtio_adapter_names();
    test_which_displays_to_keep();
    test_good();
    test_bad_names();
    test_counts_and_room();
    test_malformed_cbor();
    printf("test-windows-handlers: all checks passed\n");
    return 0;
}
