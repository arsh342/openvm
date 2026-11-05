/* smoke-tool: the small jobs the smoke tests need that the shell has no tool for.
 *
 *   smoke-tool serve <dir> <port>      serve files over HTTP, for the guest overlay
 *   smoke-tool pattern <file> <bytes>  write a known byte pattern
 *   smoke-tool has-utf16 <file> <text> exit 0 if the file holds the ASCII text as UTF-16LE
 *
 * The server is for a test guest on the host's private network: GET and HEAD only,
 * one request at a time, and no path with a dot-dot in it. */
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

static void reply(int fd, const char *status, long length) {
    char head[160];
    int n =
        snprintf(head, sizeof head,
                 "HTTP/1.0 %s\r\nContent-Length: %ld\r\nConnection: close\r\n\r\n", status, length);
    (void)!write(fd, head, (size_t)n);
}

static void serve_one(int fd, const char *dir, const char *peer) {
    char request[2048];
    size_t got = 0;
    while (got < sizeof request - 1) {
        ssize_t n = read(fd, request + got, sizeof request - 1 - got);
        if (n <= 0)
            break;
        got += (size_t)n;
        request[got] = '\0';
        if (strstr(request, "\r\n\r\n") != NULL)
            break;
    }
    request[got] = '\0';
    char method[8], target[1024];
    if (sscanf(request, "%7s %1023s", method, target) != 2 || target[0] != '/' ||
        strstr(target, "..") != NULL ||
        (strcmp(method, "GET") != 0 && strcmp(method, "HEAD") != 0)) {
        reply(fd, "400 Bad Request", 0);
        printf("%s - - \"%.60s\" 400 -\n", peer, request);
        return;
    }
    char path[1400];
    snprintf(path, sizeof path, "%s%s", dir, target);
    struct stat st;
    int file = open(path, O_RDONLY);
    if (file < 0 || fstat(file, &st) != 0 || !S_ISREG(st.st_mode)) {
        reply(fd, "404 Not Found", 0);
        printf("%s - - \"%s %s\" 404 -\n", peer, method, target);
        if (file >= 0)
            close(file);
        return;
    }
    reply(fd, "200 OK", (long)st.st_size);
    if (strcmp(method, "GET") == 0) {
        char chunk[65536];
        ssize_t n;
        while ((n = read(file, chunk, sizeof chunk)) > 0) {
            ssize_t sent = 0;
            while (sent < n) {
                ssize_t w = write(fd, chunk + sent, (size_t)(n - sent));
                if (w <= 0) {
                    n = 0;
                    break;
                }
                sent += w;
            }
            if (n == 0)
                break;
        }
    }
    close(file);
    printf("%s - - \"%s %s\" 200 -\n", peer, method, target);
}

static int serve(const char *dir, int port) {
    signal(SIGPIPE, SIG_IGN);
    setvbuf(stdout, NULL, _IOLBF, 0);
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    int on = 1;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons((unsigned short)port);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(listener, (struct sockaddr *)&addr, sizeof addr) != 0 || listen(listener, 16) != 0) {
        perror("smoke-tool: listen");
        return 1;
    }
    for (;;) {
        struct sockaddr_in from;
        socklen_t from_len = sizeof from;
        int fd = accept(listener, (struct sockaddr *)&from, &from_len);
        if (fd < 0)
            continue;
        serve_one(fd, dir, inet_ntoa(from.sin_addr));
        close(fd);
    }
}

static int pattern(const char *path, long count) {
    FILE *f = fopen(path, "wb");
    if (f == NULL)
        return 1;
    for (long i = 0; i < count; i++)
        fputc((int)((i * 37) % 256), f);
    return fclose(f) == 0 ? 0 : 1;
}

static int has_utf16(const char *path, const char *text) {
    int file = open(path, O_RDONLY);
    struct stat st;
    if (file < 0 || fstat(file, &st) != 0)
        return 2;
    const unsigned char *data = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, file, 0);
    if (data == MAP_FAILED)
        return 2;
    size_t n = strlen(text), size = (size_t)st.st_size;
    for (size_t i = 0; i + n * 2 <= size; i++) {
        size_t k = 0;
        while (k < n && data[i + k * 2] == (unsigned char)text[k] && data[i + k * 2 + 1] == 0)
            k++;
        if (k == n)
            return 0;
    }
    return 1;
}

int main(int argc, char **argv) {
    if (argc == 4 && strcmp(argv[1], "serve") == 0)
        return serve(argv[2], atoi(argv[3]));
    if (argc == 4 && strcmp(argv[1], "pattern") == 0)
        return pattern(argv[2], atol(argv[3]));
    if (argc == 4 && strcmp(argv[1], "has-utf16") == 0)
        return has_utf16(argv[2], argv[3]);
    fprintf(stderr, "usage: smoke-tool serve <dir> <port> | pattern <file> <bytes> | has-utf16 "
                    "<file> <text>\n");
    return 2;
}
