/* ---------- log ----------------------------------------------------------- */

/* agent.log beside the executable (C:\openvm\agent.log). The host reads it
 * off the guest disk when something does not answer, so every state change of
 * the channel is written; per-request traffic is not. */
static WCHAR g_log_path[MAX_PATH];
static int g_console;

static void agent_log(const char *fmt, ...) {
    char line[512];
    SYSTEMTIME t;
    GetLocalTime(&t);
    int n = snprintf(line, sizeof line, "%04u-%02u-%02u %02u:%02u:%02u ", t.wYear, t.wMonth, t.wDay,
                     t.wHour, t.wMinute, t.wSecond);
    if (n < 0)
        return;
    va_list ap;
    va_start(ap, fmt);
    int m = vsnprintf(line + n, sizeof line - (size_t)n - 2, fmt, ap);
    va_end(ap);
    if (m < 0)
        return;
    size_t len =
        (size_t)n +
        ((size_t)m < sizeof line - (size_t)n - 2 ? (size_t)m : sizeof line - (size_t)n - 3);
    line[len++] = '\r';
    line[len++] = '\n';
    if (g_console)
        fwrite(line, 1, len, stderr);
    if (!g_log_path[0])
        return;
    HANDLE f = CreateFileW(g_log_path, FILE_APPEND_DATA, FILE_SHARE_READ, NULL, OPEN_ALWAYS,
                           FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE)
        return;
    DWORD did = 0;
    WriteFile(f, line, (DWORD)len, &did, NULL);
    CloseHandle(f);
}

static void log_init(void) {
    DWORD n = GetModuleFileNameW(NULL, g_log_path, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) {
        g_log_path[0] = 0;
        return;
    }
    while (n > 0 && g_log_path[n - 1] != L'\\')
        n--;
    static const WCHAR name[] = L"agent.log";
    if (n + sizeof name / sizeof name[0] > MAX_PATH) {
        g_log_path[0] = 0;
        return;
    }
    for (size_t i = 0; i < sizeof name / sizeof name[0]; i++)
        g_log_path[n + i] = name[i];
    /* Start over past 1 MiB rather than grow without bound. */
    WIN32_FILE_ATTRIBUTE_DATA info;
    if (GetFileAttributesExW(g_log_path, GetFileExInfoStandard, &info) &&
        (info.nFileSizeHigh != 0 || info.nFileSizeLow > (1u << 20)))
        DeleteFileW(g_log_path);
}
