/* ---------- OVMC frame layer -------------------------------------------- */
static int write_all(int fd, const uint8_t *b, size_t n) {
    size_t off = 0;
    while (off < n) {
        ssize_t k = write(fd, b + off, n - off);
        if (k < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        off += (size_t)k;
    }
    return 0;
}

static void write_reply(int fd, uint16_t type, const uint8_t *body, size_t blen) {
    if (blen > OVMC_MAX_PAYLOAD)
        return;
    uint8_t *out = malloc(OVMC_FRAME_HEADER + blen);
    if (!out)
        return;
    memcpy(out, OVMC_MAGIC, 4);
    out[4] = 0;
    out[5] = 1; /* version 1 */
    out[6] = (uint8_t)(type >> 8);
    out[7] = (uint8_t)type;
    out[8] = 0;
    out[9] = 0; /* flags 0 */
    out[10] = (uint8_t)(blen >> 24);
    out[11] = (uint8_t)(blen >> 16);
    out[12] = (uint8_t)(blen >> 8);
    out[13] = (uint8_t)blen;
    if (blen)
        memcpy(out + OVMC_FRAME_HEADER, body, blen);
    write_all(fd, out, OVMC_FRAME_HEADER + blen);
    free(out);
}

static void emit_error(int fd, uint64_t cid, uint64_t errno_val, const char *msg) {
    struct ovmc_out w = {.n = 0, .ok = 1};
    ovmc_whdr(&w, 5, 3); /* errno, message, id */
    ovmc_wtext(&w, "errno");
    ovmc_wuint(&w, errno_val);
    ovmc_wtext(&w, "message");
    ovmc_wtext(&w, msg);
    ovmc_wtext(&w, "id");
    ovmc_wuint(&w, cid);
    if (!w.ok)
        return;
    write_reply(fd, T_ERROR, w.b, w.n);
}
