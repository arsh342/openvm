/* ---------- guest state -------------------------------------------------- */

#define PRODUCT_NAME "openvm-tools"
#define PRODUCT_VERSION 1u

/* Clipboard text. Windows has a real clipboard API (OpenClipboard/
 * GetClipboardData/SetClipboardData with CF_UNICODETEXT); the agent converts
 * to and from UTF-8 at the boundary. Kept behind a small pair of functions so
 * the protocol handlers stay identical to the Linux agent's. */

static int utf8_to_wide(const char *in, size_t in_len, wchar_t *out, size_t out_cap) {
    /* MultiByteToWideChar is the only correct conversion; a hand-rolled one
     * gets surrogate pairs wrong. */
#ifdef OPENVM_REAL_WIN32
    int n = MultiByteToWideChar(CP_UTF8, 0, in, (int)in_len, out, (int)(out_cap - 1));
    if (n <= 0)
        return -1;
    out[n] = 0;
    return n;
#else
    (void)in;
    (void)in_len;
    (void)out;
    (void)out_cap;
    return -1;
#endif
}

static int wide_to_utf8(const wchar_t *in, char *out, size_t out_cap) {
#ifdef OPENVM_REAL_WIN32
    int n = WideCharToMultiByte(CP_UTF8, 0, in, -1, out, (int)out_cap, NULL, NULL);
    if (n <= 0)
        return -1;
    return n - 1; /* exclude the terminator */
#else
    (void)in;
    (void)out;
    (void)out_cap;
    return -1;
#endif
}

/* Why the last user-session helper failed, for the reply. NULL: no backend. */
static const char *g_helper_error;

#ifdef OPENVM_REAL_WIN32
/* OpenClipboard(NULL) leaves the clipboard without an owner, and Windows then
 * refuses SetClipboardData. A message-only window is the cheapest owner. The
 * data is not delay-rendered, so it outlives the window and this process. */
static HWND clipboard_owner(void) {
    static HWND owner;
    if (owner == NULL)
        owner = CreateWindowExW(0, L"STATIC", L"openvm-clipboard", 0, 0, 0, 0, 0, HWND_MESSAGE,
                                NULL, GetModuleHandleW(NULL), NULL);
    return owner;
}

/* Another application can hold the clipboard open for a moment; retry briefly
 * instead of failing the host's request. */
static int clipboard_open(void) {
    HWND owner = clipboard_owner();
    for (int i = 0; i < 25; i++) {
        if (OpenClipboard(owner))
            return 1;
        Sleep(20);
    }
    g_helper_error = "the guest clipboard is held open by another application";
    return 0;
}
#endif

/* The clipboard of the session this process runs in. An empty clipboard is
 * empty text, not an error. */
static int clipboard_read_local(char *out, size_t cap, size_t *len) {
#ifdef OPENVM_REAL_WIN32
    if (!clipboard_open())
        return 0;
    HANDLE h = GetClipboardData(CF_UNICODETEXT);
    if (h == NULL) {
        CloseClipboard();
        *len = 0;
        return 1;
    }
    const wchar_t *w = (const wchar_t *)GlobalLock(h);
    if (w == NULL) {
        CloseClipboard();
        g_helper_error = "could not lock the clipboard text";
        return 0;
    }
    int n = wide_to_utf8(w, out, cap);
    GlobalUnlock(h);
    CloseClipboard();
    if (n < 0) {
        g_helper_error = "clipboard text does not fit a frame";
        return 0;
    }
    *len = (size_t)n;
    return 1;
#else
    (void)out;
    (void)cap;
    (void)len;
    return 0;
#endif
}

static int clipboard_write_local(const char *text, size_t len) {
#ifdef OPENVM_REAL_WIN32
    /* Static: the frame cap bounds `len`, so no allocation is needed. */
    static wchar_t w[OVMC_MAX_PAYLOAD / 2 + 1];
    if (len > OVMC_MAX_PAYLOAD / 2) {
        g_helper_error = "clipboard text is too long";
        return 0;
    }
    if (len == 0)
        w[0] = 0;
    else if (utf8_to_wide(text, len, w, len + 1) < 0) {
        g_helper_error = "clipboard text is not valid UTF-8";
        return 0;
    }
    size_t bytes = (wcslen(w) + 1) * sizeof(wchar_t);
    HGLOBAL h = GlobalAlloc(GMEM_MOVEABLE, bytes);
    if (h == NULL)
        return 0;
    void *dst = GlobalLock(h);
    if (dst == NULL) {
        GlobalFree(h);
        return 0;
    }
    ovmc_memcpy(dst, w, bytes);
    GlobalUnlock(h);
    if (!clipboard_open()) {
        GlobalFree(h);
        return 0;
    }
    EmptyClipboard();
    if (SetClipboardData(CF_UNICODETEXT, h) == NULL) {
        CloseClipboard();
        GlobalFree(h);
        g_helper_error = "SetClipboardData refused the text";
        return 0;
    }
    CloseClipboard();
    return 1; /* the clipboard owns h now */
#else
    (void)text;
    (void)len;
    return 0;
#endif
}

#ifdef OPENVM_REAL_WIN32
static int in_session_zero(void) {
    DWORD session = 1;
    return ProcessIdToSessionId(GetCurrentProcessId(), &session) && session == 0;
}

/* The agent serves one request at a time, so a child that hangs would stop ping
 * and everything else with it. Output is read only as it arrives, against a
 * deadline; a child past it is killed. Returns 0 on timeout. */
static int read_child(HANDLE pipe, HANDLE process, uint8_t *out, size_t cap, size_t *got,
                      DWORD timeout_ms) {
    ULONGLONG deadline = GetTickCount64() + timeout_ms;
    *got = 0;
    for (;;) {
        DWORD ready = 0;
        if (!PeekNamedPipe(pipe, NULL, 0, NULL, &ready, NULL))
            return 1; /* every writer closed: the child is done */
        if (ready > 0 && *got < cap) {
            DWORD want = (DWORD)(cap - *got), did = 0;
            if (want > ready)
                want = ready;
            if (!ReadFile(pipe, out + *got, want, &did, NULL) || did == 0)
                return 1;
            *got += did;
            continue;
        }
        if (GetTickCount64() >= deadline) {
            TerminateProcess(process, 1);
            return 0;
        }
        Sleep(20);
    }
}

/* Runs this executable with `mode` in the console user's session, feeds it
 * `in` on stdin and collects its stdout. Used for what a session-0 service
 * cannot reach: the clipboard, the user's default printer, printing as the
 * user. Returns 1 when the child exited 0. */
struct session_child {
    HANDLE process, thread, in_w, out_r;
};

static int start_in_user_session(const WCHAR *mode, struct session_child *child) {
    DWORD session = WTSGetActiveConsoleSessionId();
    HANDLE user = NULL;
    if (session == 0xFFFFFFFFu || !WTSQueryUserToken(session, &user)) {
        g_helper_error = "no user is logged on to the guest console";
        return 0;
    }

    WCHAR exe[MAX_PATH];
    DWORD n = GetModuleFileNameW(NULL, exe, MAX_PATH);
    WCHAR cmd[MAX_PATH + 160];
    if (n == 0 || n >= MAX_PATH) {
        CloseHandle(user);
        return 0;
    }
    size_t c = 0;
    cmd[c++] = L'"';
    for (DWORD i = 0; i < n; i++)
        cmd[c++] = exe[i];
    cmd[c++] = L'"';
    cmd[c++] = L' ';
    for (const WCHAR *m = mode; *m && c < MAX_PATH + 158; m++)
        cmd[c++] = *m;
    cmd[c] = 0;

    SECURITY_ATTRIBUTES sa = {sizeof sa, NULL, TRUE};
    HANDLE in_r = NULL, in_w = NULL, out_r = NULL, out_w = NULL;
    if (!CreatePipe(&in_r, &in_w, &sa, 0)) {
        CloseHandle(user);
        return 0;
    }
    if (!CreatePipe(&out_r, &out_w, &sa, 0)) {
        CloseHandle(in_r);
        CloseHandle(in_w);
        CloseHandle(user);
        return 0;
    }
    SetHandleInformation(in_w, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(out_r, HANDLE_FLAG_INHERIT, 0);

    /* Only the two pipe ends are inherited: Winsock sockets are inheritable
     * by default, and a child holding the host's connection would keep it
     * open past closesocket. */
    HANDLE inherit[2] = {in_r, out_w};
    SIZE_T attr_size = 0;
    InitializeProcThreadAttributeList(NULL, 1, 0, &attr_size);
    static uint64_t attr_buf[32]; /* 256 bytes, pointer-aligned */
    LPPROC_THREAD_ATTRIBUTE_LIST attrs = (LPPROC_THREAD_ATTRIBUTE_LIST)attr_buf;
    int have_attrs = attr_size <= sizeof attr_buf &&
                     InitializeProcThreadAttributeList(attrs, 1, 0, &attr_size) &&
                     UpdateProcThreadAttribute(attrs, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, inherit,
                                               sizeof inherit, NULL, NULL);

    static WCHAR desktop[] = L"winsta0\\default";
    STARTUPINFOEXW si;
    ovmc_memset_zero(&si, sizeof si);
    si.StartupInfo.cb = sizeof si;
    si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    si.StartupInfo.hStdInput = in_r;
    si.StartupInfo.hStdOutput = out_w;
    si.StartupInfo.hStdError = out_w;
    si.StartupInfo.lpDesktop = desktop;
    si.lpAttributeList = have_attrs ? attrs : NULL;
    PROCESS_INFORMATION pi;
    ovmc_memset_zero(&pi, sizeof pi);
    /* CreateProcessAsUser otherwise passes on SYSTEM's environment, and the shell
     * then cannot resolve the user's known folders. */
    LPVOID environment = NULL;
    int have_env = CreateEnvironmentBlock(&environment, user, FALSE);
    BOOL started = have_attrs && have_env &&
                   CreateProcessAsUserW(user, exe, cmd, NULL, NULL, TRUE,
                                        CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT |
                                            CREATE_UNICODE_ENVIRONMENT,
                                        environment, NULL, &si.StartupInfo, &pi);
    if (have_env)
        DestroyEnvironmentBlock(environment);
    if (have_attrs)
        DeleteProcThreadAttributeList(attrs);
    CloseHandle(user);
    CloseHandle(in_r);
    CloseHandle(out_w);
    if (!started) {
        CloseHandle(in_w);
        CloseHandle(out_r);
        g_helper_error = "could not start the helper in the user session";
        return 0;
    }

    child->process = pi.hProcess;
    child->thread = pi.hThread;
    child->in_w = in_w;
    child->out_r = out_r;
    return 1;
}

static void child_write_all(struct session_child *child, const uint8_t *in, size_t in_len) {
    size_t sent = 0;
    while (sent < in_len) {
        DWORD did = 0;
        DWORD want = (DWORD)(in_len - sent > 0x10000 ? 0x10000 : in_len - sent);
        if (!WriteFile(child->in_w, in + sent, want, &did, NULL) || did == 0)
            break;
        sent += did;
    }
    CloseHandle(child->in_w);
    child->in_w = NULL;
}

static int run_in_user_session(const WCHAR *mode, const uint8_t *in, size_t in_len, uint8_t *out,
                               size_t cap, size_t *out_len) {
    struct session_child child;
    *out_len = 0;
    if (!start_in_user_session(mode, &child))
        return 0;
    child_write_all(&child, in, in_len);
    size_t got = 0;
    int finished = read_child(child.out_r, child.process, out, cap, &got, 15000);
    CloseHandle(child.out_r);

    DWORD code = 1;
    if (WaitForSingleObject(child.process, 2000) != WAIT_OBJECT_0)
        TerminateProcess(child.process, 1);
    GetExitCodeProcess(child.process, &code);
    CloseHandle(child.thread);
    CloseHandle(child.process);
    if (!finished) {
        agent_log("user-session helper timed out");
        g_helper_error = "the user-session helper timed out";
        return 0;
    }
    *out_len = got;
    if (code != 0) {
        /* The helper writes its reason instead of text when it fails. */
        static char reason[160];
        size_t k = got < sizeof reason - 1 ? got : sizeof reason - 1;
        ovmc_memcpy(reason, out, k);
        reason[k] = 0;
        g_helper_error = k ? reason : "the user-session helper failed";
        return 0;
    }
    return 1;
}
#endif

static int clipboard_read(char *out, size_t cap, size_t *len) {
    g_helper_error = NULL;
#ifdef OPENVM_REAL_WIN32
    if (in_session_zero())
        return run_in_user_session(L"--clipboard-read", NULL, 0, (uint8_t *)out, cap, len);
#endif
    return clipboard_read_local(out, cap, len);
}

static int clipboard_write(const char *text, size_t len) {
    g_helper_error = NULL;
#ifdef OPENVM_REAL_WIN32
    if (in_session_zero()) {
        uint8_t reply[160];
        size_t got = 0;
        return run_in_user_session(L"--clipboard-write", (const uint8_t *)text, len, reply,
                                   sizeof reply, &got);
    }
#endif
    return clipboard_write_local(text, len);
}
