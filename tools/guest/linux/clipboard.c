/* The clipboard (8/9), through the logged-on desktop session. */

static void clipboard_response(int fd, uint64_t cid, const char *error, const uint8_t *text,
                               size_t text_length, int include_text) {
    struct ovmc_out w = {.n = 0, .ok = 1};
    ovmc_whdr(&w, 5, error ? 2 : (include_text ? 2 : 1));
    if (error) {
        ovmc_wtext(&w, "error");
        ovmc_wtext(&w, error);
    } else if (include_text) {
        ovmc_wtext(&w, "text");
        ovmc_wtextn(&w, text, text_length);
    }
    ovmc_wtext(&w, "id");
    ovmc_wuint(&w, cid);
    if (w.ok)
        write_reply(fd, T_CLIPBOARD_REPLY, w.b, w.n);
}

static int valid_utf8(const uint8_t *s, size_t n) {
    size_t i = 0;
    while (i < n) {
        uint8_t a = s[i++];
        if (a <= 0x7f)
            continue;
        if (a >= 0xc2 && a <= 0xdf) {
            if (i >= n || (s[i++] & 0xc0) != 0x80)
                return 0;
            continue;
        }
        if (a >= 0xe0 && a <= 0xef) {
            if (i + 1 >= n)
                return 0;
            uint8_t b = s[i++], c = s[i++];
            if ((c & 0xc0) != 0x80 || (b & 0xc0) != 0x80 || (a == 0xe0 && b < 0xa0) ||
                (a == 0xed && b >= 0xa0))
                return 0;
            continue;
        }
        if (a >= 0xf0 && a <= 0xf4) {
            if (i + 2 >= n)
                return 0;
            uint8_t b = s[i++], c = s[i++], d = s[i++];
            if ((b & 0xc0) != 0x80 || (c & 0xc0) != 0x80 || (d & 0xc0) != 0x80 ||
                (a == 0xf0 && b < 0x90) || (a == 0xf4 && b >= 0x90))
                return 0;
            continue;
        }
        return 0;
    }
    return 1;
}

static void handle_clipboard(int fd, const uint8_t *body, const struct ovmc_pair *pairs,
                             size_t count, uint64_t cid) {
    const struct ovmc_pair *op_pair = find_pair(body, pairs, count, "op");
    const uint8_t *op;
    size_t op_length;
    if (!op_pair ||
        !ovmc_text_span(body + op_pair->v0, op_pair->v1 - op_pair->v0, &op, &op_length)) {
        clipboard_response(fd, cid, "clipboard request is missing op", NULL, 0, 0);
        return;
    }

    int writing = op_length == 5 && memcmp(op, "write", 5) == 0;
    int reading = op_length == 4 && memcmp(op, "read", 4) == 0;
    if (!writing && !reading) {
        clipboard_response(fd, cid, "clipboard op must be read or write", NULL, 0, 0);
        return;
    }

    const struct ovmc_pair *text_pair = writing ? find_pair(body, pairs, count, "text") : NULL;
    const uint8_t *input = NULL;
    size_t input_length = 0;
    if (writing &&
        (!text_pair || !ovmc_text_span(body + text_pair->v0, text_pair->v1 - text_pair->v0, &input,
                                       &input_length))) {
        clipboard_response(fd, cid, "clipboard write is missing text", NULL, 0, 0);
        return;
    }

    if (writing) {
        FILE *pipe = popen("/opt/openvm/openvm-clipboard-backend.sh write", "w");
        if (!pipe) {
            clipboard_response(fd, cid, "could not start guest clipboard backend", NULL, 0, 0);
            return;
        }
        int failed = input_length && fwrite(input, 1, input_length, pipe) != input_length;
        int status = pclose(pipe);
        if (failed || status == -1 || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
            clipboard_response(
                fd, cid, "guest clipboard write failed (is a desktop session active?)", NULL, 0, 0);
            return;
        }
        clipboard_response(fd, cid, NULL, NULL, 0, 0);
        return;
    }

    FILE *pipe = popen("/opt/openvm/openvm-clipboard-backend.sh read", "r");
    if (!pipe) {
        clipboard_response(fd, cid, "could not start guest clipboard backend", NULL, 0, 0);
        return;
    }
    const size_t output_capacity = OVMC_MAX_PAYLOAD - 256;
    uint8_t *output = malloc(output_capacity);
    if (!output) {
        pclose(pipe);
        clipboard_response(fd, cid, "guest clipboard allocation failed", NULL, 0, 0);
        return;
    }
    size_t output_length = fread(output, 1, output_capacity, pipe);
    int overflow = output_length == output_capacity && fgetc(pipe) != EOF;
    int status = pclose(pipe);
    if (overflow || status == -1 || !WIFEXITED(status) || WEXITSTATUS(status) != 0 ||
        !valid_utf8(output, output_length)) {
        const char *error = overflow ? "guest clipboard text exceeds the frame limit"
                            : (status == -1 || !WIFEXITED(status) || WEXITSTATUS(status) != 0)
                                ? "guest clipboard read failed (is a desktop session active?)"
                                : "guest clipboard returned invalid UTF-8";
        free(output);
        clipboard_response(fd, cid, error, NULL, 0, 0);
        return;
    }
    clipboard_response(fd, cid, NULL, output, output_length, 1);
    free(output);
}
