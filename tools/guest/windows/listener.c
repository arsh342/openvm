/* ---------- vsock listener ------------------------------------------------ */

/* viosock's sockaddr_vm (viosock/inc/vio_sockets.h): 12 bytes. The Linux
 * layout has a 4-byte svm_zero tail; this one does not. */
struct viosock_addr {
    ADDRESS_FAMILY svm_family;
    USHORT svm_reserved1;
    UINT svm_port;
    UINT svm_cid;
};

#define VIOSOCK_AF_FALLBACK 40
#define VIOSOCK_IOCTL_GET_AF 0x0801300C
#define VIOSOCK_CID_ANY 0xFFFFFFFFu
#define ACCEPT_POLL_MS 50

/* The driver hands out the family number its provider registered. 40 is the
 * value every released driver uses, kept as the fallback. */
static int viosock_family(void) {
    DWORD af = 0;
    HANDLE h = CreateFileW(L"\\\\.\\Viosock", GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                           FILE_ATTRIBUTE_NORMAL, NULL);
    if (h != INVALID_HANDLE_VALUE) {
        DWORD got = 0;
        if (!DeviceIoControl(h, VIOSOCK_IOCTL_GET_AF, NULL, 0, &af, sizeof af, &got, NULL))
            af = 0;
        CloseHandle(h);
    }
    return af ? (int)af : VIOSOCK_AF_FALLBACK;
}

static volatile LONG g_stop;

#ifdef OPENVM_AGENT_TRACE
/* Diagnosis build. A second thread proves the process is still scheduled while
 * the channel is quiet, and says what the accept loop was doing. */
static volatile LONG g_accepted;

static DWORD WINAPI trace_thread(LPVOID unused) {
    (void)unused;
    ULONGLONG last = GetTickCount64();
    for (unsigned n = 0;; n++) {
        Sleep(5000);
        ULONGLONG now = GetTickCount64();
        ULONGLONG gap = now - last;
        last = now;
        if (gap > 8000 || n % 12 == 0)
            agent_log("trace: heartbeat gap=%llums accepted=%ld", gap, g_accepted);
    }
    return 0;
}
#endif

/* Bind and listen on vsock port 52, then serve connections one at a time
 * (the host opens one per exchange). A failure to open the listener is
 * retried every two seconds: the Winsock provider is its own service and can
 * start after this one, and the device can be reset under us. */
static int run_agent(void) {
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        agent_log("WSAStartup failed");
        return 1;
    }
    agent_log("openvm-tools %u starting (pid %lu)", PRODUCT_VERSION, GetCurrentProcessId());
#ifdef OPENVM_AGENT_TRACE
    CreateThread(NULL, 0, trace_thread, NULL, 0, NULL);
#endif
    unsigned failures = 0;
    while (!g_stop) {
        int af = viosock_family();
        SOCKET s = socket(af, SOCK_STREAM, 0);
        const char *step = "socket";
        if (s != INVALID_SOCKET) {
            struct viosock_addr addr;
            ovmc_memset_zero(&addr, sizeof addr);
            addr.svm_family = (ADDRESS_FAMILY)af;
            addr.svm_port = OVMC_VSOCK_PORT;
            addr.svm_cid = VIOSOCK_CID_ANY;
            step = "bind";
            if (bind(s, (const struct sockaddr *)&addr, (int)sizeof addr) == 0) {
                step = "listen";
                if (listen(s, 8) == 0)
                    step = NULL;
            }
        }
        if (step != NULL) {
            int err = WSAGetLastError();
            if (s != INVALID_SOCKET)
                closesocket(s);
            /* First failure, then once a minute: the log should show the
             * provider coming up late without filling with retries. */
            if (failures % 30 == 0)
                agent_log("%s failed on AF %d: WSA error %d (retrying)", step, af, err);
            failures++;
            Sleep(2000);
            continue;
        }
        /* Never let accept() pend in the driver. viosock 0.1.302 has a lost wakeup
         * there: a connection arriving as accept() pends is missed and accept()
         * sleeps forever (virtio-win #1684, unmerged fix #1685). Polling is also
         * why this is not select(): select() misses connections queued behind
         * the first, and cancelling it can bugcheck (#1692). A non-blocking
         * accept must pass no peer address, or a connection the peer already
         * reset fails it with WSAEINVAL. */
        u_long nonblocking = 1;
        if (ioctlsocket(s, FIONBIO, &nonblocking) != 0)
            agent_log("could not make the listener non-blocking: WSA error %d", WSAGetLastError());
        g_listen = s;
        agent_log("listening on vsock port %u (AF %d)", OVMC_VSOCK_PORT, af);
        failures = 0;
        unsigned accept_errors = 0;
        while (!g_stop) {
            SOCKET c = accept(s, NULL, NULL);
            if (c == INVALID_SOCKET) {
                int err = WSAGetLastError();
                if (g_stop)
                    break;
                if (err == WSAEWOULDBLOCK) {
                    Sleep(ACCEPT_POLL_MS);
                    continue;
                }
                agent_log("accept failed: WSA error %d", err);
                if (++accept_errors >= 10)
                    break; /* re-open the listener */
                Sleep(200);
                continue;
            }
#ifdef OPENVM_AGENT_TRACE
            InterlockedIncrement(&g_accepted);
#endif
            accept_errors = 0;
            serve_connection(c);
            closesocket(c);
        }
        g_listen = INVALID_SOCKET;
        closesocket(s);
    }
    agent_log("stopping");
    WSACleanup();
    return 0;
}
