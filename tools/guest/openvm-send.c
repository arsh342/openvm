/* openvm-send — sends files and folders from this guest to the Mac.
 *
 *   openvm-send [-o outbox] path...
 *
 * The outbox is the guest's view of a folder the host watches (default /run/openvm-fs/outbox). A send
 * is built under a hidden name, marked complete with a `.ready` file listing the top-level names,
 * and then renamed into place: the host sees one event, and never a half-written set.
 *
 * It runs as the person using the guest, with their own permissions. Only plain files and folders
 * are sent; a link, device or pipe stops the whole send, because a link could name a guest file the
 * person never meant to share, and the host refuses such a set anyway. */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#ifndef OPENVM_OUTBOX
#define OPENVM_OUTBOX "/run/openvm-fs/outbox"
#endif

#define MAX_ITEMS 64
#define MAX_DEPTH 32
#define MAX_ENTRIES 100000
#define NAME_MAX_BYTES 255

static long g_entries;

static int fail(const char *what, const char *path) {
    if (path != NULL)
        fprintf(stderr, "openvm-send: %s: %s\n", what, path);
    else
        fprintf(stderr, "openvm-send: %s\n", what);
    return -1;
}

static int refuse(const char *what, const char *path) {
    fail(what, path);
    return 1;
}

/* The same rules the host applies to a name: no separator or control character, 1..255 bytes,
 * not "." or "..". */
static int valid_name(const char *name) {
    size_t n = strlen(name);
    if (n == 0 || n > NAME_MAX_BYTES || strcmp(name, ".") == 0 || strcmp(name, "..") == 0)
        return 0;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)name[i];
        if (c == '/' || c < 0x20 || c == 0x7f)
            return 0;
    }
    return 1;
}

static int copy_file(const char *src, const char *dst) {
    /* O_NOFOLLOW: a link swapped in after the check is refused, not followed. */
    int in = open(src, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (in < 0)
        return fail("cannot read", src);
    struct stat st;
    if (fstat(in, &st) != 0 || !S_ISREG(st.st_mode)) {
        close(in);
        return fail("not a plain file", src);
    }
    int out = open(dst, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
    if (out < 0) {
        close(in);
        return fail("cannot create", dst);
    }
    static char buf[1 << 20];
    int rc = 0;
    for (;;) {
        ssize_t n = read(in, buf, sizeof buf);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            rc = fail("read failed", src);
            break;
        }
        if (n == 0)
            break;
        for (ssize_t off = 0; off < n;) {
            ssize_t w = write(out, buf + off, (size_t)(n - off));
            if (w < 0) {
                if (errno == EINTR)
                    continue;
                rc = fail("write failed", dst);
                goto done;
            }
            off += w;
        }
    }
done:
    if (close(out) != 0 && rc == 0)
        rc = fail("write failed", dst);
    close(in);
    return rc;
}

static int copy_tree(const char *src, const char *dst, int depth) {
    if (++g_entries > MAX_ENTRIES)
        return fail("too many files", src);
    struct stat st;
    if (lstat(src, &st) != 0)
        return fail("cannot read", src);
    if (S_ISREG(st.st_mode))
        return copy_file(src, dst);
    if (!S_ISDIR(st.st_mode))
        return fail("not a plain file or folder", src);
    if (depth >= MAX_DEPTH)
        return fail("folders nested too deeply", src);
    if (mkdir(dst, 0755) != 0)
        return fail("cannot create", dst);
    DIR *d = opendir(src);
    if (d == NULL)
        return fail("cannot read", src);
    int rc = 0;
    struct dirent *e;
    while (rc == 0 && (e = readdir(d)) != NULL) {
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0)
            continue;
        if (!valid_name(e->d_name)) {
            rc = fail("cannot send a file with this name", e->d_name);
            break;
        }
        char s[PATH_MAX], t[PATH_MAX];
        if (snprintf(s, sizeof s, "%s/%s", src, e->d_name) >= (int)sizeof s ||
            snprintf(t, sizeof t, "%s/%s", dst, e->d_name) >= (int)sizeof t) {
            rc = fail("path too long", src);
            break;
        }
        rc = copy_tree(s, t, depth + 1);
    }
    closedir(d);
    return rc;
}

static void remove_tree(const char *path) {
    struct stat st;
    if (lstat(path, &st) != 0)
        return;
    if (S_ISDIR(st.st_mode)) {
        DIR *d = opendir(path);
        if (d != NULL) {
            struct dirent *e;
            while ((e = readdir(d)) != NULL) {
                if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0)
                    continue;
                char child[PATH_MAX];
                if (snprintf(child, sizeof child, "%s/%s", path, e->d_name) < (int)sizeof child)
                    remove_tree(child);
            }
            closedir(d);
        }
        rmdir(path);
    } else {
        unlink(path);
    }
}

static const char *base_name(const char *path) {
    const char *slash = strrchr(path, '/');
    return slash != NULL ? slash + 1 : path;
}

int main(int argc, char **argv) {
    const char *outbox = getenv("OPENVM_OUTBOX");
    if (outbox == NULL || *outbox == '\0')
        outbox = OPENVM_OUTBOX;
    int first = 1;
    if (argc > 2 && strcmp(argv[1], "-o") == 0) {
        outbox = argv[2];
        first = 3;
    }
    int count = argc - first;
    if (count < 1) {
        fprintf(stderr, "usage: openvm-send [-o outbox] path...\n");
        return 2;
    }
    if (count > MAX_ITEMS)
        return refuse("too many items (the most is 64)", NULL);

    /* Check every name before anything is copied. */
    for (int i = first; i < argc; i++) {
        /* A trailing slash on a folder is fine; the name is what comes before it. */
        char path[PATH_MAX];
        snprintf(path, sizeof path, "%s", argv[i]);
        size_t n = strlen(path);
        while (n > 1 && path[n - 1] == '/')
            path[--n] = '\0';
        const char *name = base_name(path);
        if (!valid_name(name) || strcmp(name, ".ready") == 0)
            return refuse("cannot send a file with this name", name);
        for (int j = first; j < i; j++) {
            char other[PATH_MAX];
            snprintf(other, sizeof other, "%s", argv[j]);
            size_t m = strlen(other);
            while (m > 1 && other[m - 1] == '/')
                other[--m] = '\0';
            if (strcmp(base_name(other), name) == 0)
                return refuse("two items have the same name", name);
        }
    }

    char id[64], hidden[PATH_MAX], final[PATH_MAX];
    snprintf(id, sizeof id, "%ld-%d", (long)time(NULL), (int)getpid());
    if (snprintf(hidden, sizeof hidden, "%s/.incoming-%s", outbox, id) >= (int)sizeof hidden ||
        snprintf(final, sizeof final, "%s/%s", outbox, id) >= (int)sizeof final)
        return refuse("outbox path too long", outbox);
    if (mkdir(hidden, 0755) != 0) {
        fprintf(stderr, "openvm-send: cannot use the outbox %s: %s\n", outbox, strerror(errno));
        return 1;
    }

    char manifest[PATH_MAX + 16];
    snprintf(manifest, sizeof manifest, "%s/.ready", hidden);
    FILE *list = NULL;
    int rc = 0;
    g_entries = 0;
    for (int i = first; i < argc && rc == 0; i++) {
        char path[PATH_MAX], target[PATH_MAX];
        snprintf(path, sizeof path, "%s", argv[i]);
        size_t n = strlen(path);
        while (n > 1 && path[n - 1] == '/')
            path[--n] = '\0';
        if (snprintf(target, sizeof target, "%s/%s", hidden, base_name(path)) >= (int)sizeof target) {
            rc = fail("path too long", path);
            break;
        }
        rc = copy_tree(path, target, 0);
    }
    if (rc == 0) {
        list = fopen(manifest, "w");
        if (list == NULL) {
            rc = fail("cannot write the list of files", manifest);
        } else {
            for (int i = first; i < argc; i++) {
                char path[PATH_MAX];
                snprintf(path, sizeof path, "%s", argv[i]);
                size_t n = strlen(path);
                while (n > 1 && path[n - 1] == '/')
                    path[--n] = '\0';
                fprintf(list, "%s\n", base_name(path));
            }
            if (fflush(list) != 0 || fsync(fileno(list)) != 0)
                rc = fail("cannot write the list of files", manifest);
            if (fclose(list) != 0 && rc == 0)
                rc = fail("cannot write the list of files", manifest);
        }
    }
    if (rc == 0 && rename(hidden, final) != 0)
        rc = fail("could not hand the files over", final);
    if (rc != 0) {
        remove_tree(hidden);
        return 1;
    }
    printf("sent %d item(s)\n", count);
    return 0;
}
