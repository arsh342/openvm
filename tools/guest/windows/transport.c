/* ---------- transport ---------------------------------------------------- */

/* One accepted connection. The host opens a fresh connection per exchange
 * (GuestBoot.swift: "one fresh vsock connection per ..."), so the agent
 * accepts, serves frames until the peer closes, and loops. */
static SOCKET g_listen = INVALID_SOCKET;

/* Accepted sockets are non-blocking, and stay so: they inherit it from the
 * listener (see run_agent), and viosock's FIONBIO ignores its argument, so it
 * can only ever be turned on. "Would block" therefore means "not yet", and the
 * wait lives here. A peer silent for this long has gone: the agent serves one
 * connection at a time, so it must not wait for ever. */
#define SOCK_IDLE_MS 30000

#ifdef OPENVM_REAL_WIN32
static int sock_wait(ULONGLONG *deadline) {
    if (WSAGetLastError() != WSAEWOULDBLOCK || GetTickCount64() >= *deadline)
        return 0;
    Sleep(1);
    return 1;
}
#define SOCK_DEADLINE(d) ULONGLONG d = GetTickCount64() + SOCK_IDLE_MS
#define SOCK_PROGRESS(d) (d = GetTickCount64() + SOCK_IDLE_MS)
#else
#define sock_wait(d) 0
#define SOCK_DEADLINE(d) int d = 0
#define SOCK_PROGRESS(d) ((void)d)
#endif

static int sock_send_all(SOCKET fd, const uint8_t *b, size_t n) {
    size_t off = 0;
    SOCK_DEADLINE(deadline);
    while (off < n) {
        int k = send(fd, (const char *)(b + off), (int)(n - off), 0);
        if (k < 0 && sock_wait(&deadline))
            continue;
        if (k <= 0)
            return -1;
        off += (size_t)k;
        SOCK_PROGRESS(deadline);
    }
    return 0;
}

static int sock_recv_all(SOCKET fd, uint8_t *b, size_t n) {
    size_t off = 0;
    SOCK_DEADLINE(deadline);
    while (off < n) {
        int k = recv(fd, (char *)(b + off), (int)(n - off), 0);
        if (k < 0 && sock_wait(&deadline))
            continue;
        if (k <= 0)
            return -1;
        off += (size_t)k;
        SOCK_PROGRESS(deadline);
    }
    return 0;
}

static void write_reply(SOCKET fd, uint16_t type, const uint8_t *body, size_t blen) {
    uint8_t hdr[OVMC_FRAME_HEADER];
    if (!ovmc_frame_header(hdr, type, (uint32_t)blen))
        return;
    if (sock_send_all(fd, hdr, OVMC_FRAME_HEADER) != 0)
        return;
    if (blen)
        (void)sock_send_all(fd, body, blen);
}

static void emit_error(SOCKET fd, uint64_t cid, uint64_t errno_val, const char *msg) {
    struct ovmc_out w;
    ovmc_out_init(&w);
    ovmc_whdr(&w, 5, 3);
    ovmc_wtext(&w, "errno");
    ovmc_wuint(&w, errno_val);
    ovmc_wtext(&w, "message");
    ovmc_wtext(&w, msg);
    ovmc_wtext(&w, "id");
    ovmc_wuint(&w, cid);
    if (w.ok)
        write_reply(fd, T_ERROR, w.b, w.n);
}
