/* ---------- the display after a restart -----------------------------------
 * When Windows restarts itself the VM keeps running and the framework tells the
 * host nothing, so the host never sizes the guest again: it came back at
 * 1024x768 in a window sized for 2496x1440 (measured 2026-11-12, no display
 * notification on the Mac). So the agent keeps the last mode the host asked for,
 * beside its log, and asks for it again once someone is signed in (openVM's
 * guests sign in by themselves). If the host asks for a mode first, as it does
 * on a cold start, the host's mode stands and nothing is restored. */

static volatile LONG g_stop; /* set when the service stops; defined in listener.c */

/* display-mode.txt beside agent.log. */
static int display_mode_path(WCHAR *out, size_t cap) {
    static const WCHAR name[] = L"display-mode.txt";
    size_t n = 0;
    while (g_log_path[n])
        n++;
    while (n > 0 && g_log_path[n - 1] != L'\\')
        n--;
    size_t name_len = sizeof name / sizeof name[0]; /* with its terminator */
    if (n == 0 || n + name_len > cap)
        return 0;
    for (size_t i = 0; i < n; i++)
        out[i] = g_log_path[i];
    for (size_t i = 0; i < name_len; i++)
        out[n + i] = name[i];
    return 1;
}

/* viogpudo lists, after a restart, its two fixed sizes and one more: the size the
 * Mac last set, unless its driver key holds PersistentDispMode0Width/Height, which
 * win instead (measured: 5120x2880 there, so 2496x1440 could not be restored). The
 * agent keeps them at the last size the Mac asked for, so that size is listed. */
static void display_persist(unsigned long width, unsigned long height) {
    /* GUID_DEVCLASS_DISPLAY */
    static const GUID display_class = {
        0x4d36e968, 0xe325, 0x11ce, {0xbf, 0xc1, 0x08, 0x00, 0x2b, 0xe1, 0x03, 0x18}};
    HDEVINFO set = SetupDiGetClassDevsW(&display_class, NULL, NULL, DIGCF_PRESENT);
    if (set == INVALID_HANDLE_VALUE)
        return;
    SP_DEVINFO_DATA dev;
    dev.cbSize = sizeof dev;
    for (DWORD i = 0; SetupDiEnumDeviceInfo(set, i, &dev); i++) {
        WCHAR id[200];
        char ascii[200];
        if (!SetupDiGetDeviceInstanceIdW(set, &dev, id, sizeof id / sizeof id[0], NULL))
            continue;
        size_t n = 0;
        for (; n + 1 < sizeof ascii && id[n] != 0; n++)
            ascii[n] = id[n] < 0x80 ? (char)id[n] : '?';
        ascii[n] = '\0';
        if (!display_is_virtio_adapter(ascii))
            continue;
        HKEY key = SetupDiOpenDevRegKey(set, &dev, DICS_FLAG_GLOBAL, 0, DIREG_DRV,
                                        KEY_QUERY_VALUE | KEY_SET_VALUE);
        if (key == INVALID_HANDLE_VALUE) {
            agent_log("display: cannot open the virtio GPU's driver key (%lu)", GetLastError());
            continue;
        }
        DWORD old_w = 0, old_h = 0, size = sizeof old_w;
        RegQueryValueExW(key, L"PersistentDispMode0Width", NULL, NULL, (BYTE *)&old_w, &size);
        size = sizeof old_h;
        RegQueryValueExW(key, L"PersistentDispMode0Height", NULL, NULL, (BYTE *)&old_h, &size);
        if (old_w != width || old_h != height) {
            DWORD w = (DWORD)width, h = (DWORD)height;
            if (RegSetValueExW(key, L"PersistentDispMode0Width", 0, REG_DWORD, (const BYTE *)&w,
                               sizeof w) == ERROR_SUCCESS &&
                RegSetValueExW(key, L"PersistentDispMode0Height", 0, REG_DWORD, (const BYTE *)&h,
                               sizeof h) == ERROR_SUCCESS)
                agent_log("display: viogpudo will list %lux%lu after a restart (was %lux%lu)", width,
                          height, (unsigned long)old_w, (unsigned long)old_h);
            else
                agent_log("display: cannot keep %lux%lu in the virtio GPU's driver key", width, height);
        }
        RegCloseKey(key);
    }
    SetupDiDestroyDeviceInfoList(set);
}

static void display_remember(unsigned long width, unsigned long height, unsigned long scale) {
    display_persist(width, height);
    WCHAR path[MAX_PATH];
    char text[48];
    if (!display_mode_path(path, MAX_PATH))
        return;
    int n = snprintf(text, sizeof text, "%lu %lu %lu\r\n", width, height, scale);
    if (n <= 0 || (size_t)n >= sizeof text)
        return;
    HANDLE f = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE)
        return;
    DWORD did = 0;
    WriteFile(f, text, (DWORD)n, &did, NULL);
    CloseHandle(f);
}

static int display_recall(unsigned long *width, unsigned long *height, unsigned long *scale) {
    WCHAR path[MAX_PATH];
    char text[48];
    if (!display_mode_path(path, MAX_PATH))
        return 0;
    HANDLE f = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                           FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE)
        return 0;
    DWORD got = 0;
    BOOL read = ReadFile(f, text, sizeof text - 1, &got, NULL);
    CloseHandle(f);
    if (!read)
        return 0;
    text[got] = 0;
    /* The same bounds as a request from the host. */
    return sscanf(text, "%lu %lu %lu", width, height, scale) == 3 && *width >= 640 &&
           *height >= 480 && *width <= 7680 && *height <= 4320 && *scale <= 3;
}

static DWORD WINAPI display_restore_thread(LPVOID unused) {
    (void)unused;
    unsigned long width = 0, height = 0, scale = 0;
    if (!display_recall(&width, &height, &scale))
        return 0;
    WCHAR mode[48];
    swprintf(mode, sizeof mode / sizeof mode[0], L"--display %lu %lu %lu", width, height, scale);
    /* Every 3 seconds for 10 minutes: long enough for a slow sign-in. */
    for (int tries = 0; tries < 200 && !g_stop; tries++) {
        if (g_display_asked)
            return 0;
        DWORD session = WTSGetActiveConsoleSessionId();
        HANDLE user = NULL;
        if (session != 0xFFFFFFFFu && WTSQueryUserToken(session, &user)) {
            CloseHandle(user);
            static uint8_t said[256];
            size_t got = 0;
            int ran = 0;
            AcquireSRWLockExclusive(&g_display_lock);
            if (!g_display_asked) {
                g_helper_error = NULL;
                ran = run_in_user_session(mode, NULL, 0, said, sizeof said - 1, &got);
            }
            ReleaseSRWLockExclusive(&g_display_lock);
            if (g_display_asked)
                return 0;
            unsigned long held_w = 0, held_h = 0, held_scale = 0;
            if (ran) {
                said[got] = 0;
                if (sscanf((const char *)said, "%lux%lu@%lu", &held_w, &held_h, &held_scale) >= 2) {
                    agent_log("display restored to %lux%lu at scale %lu after a restart", held_w,
                              held_h, held_scale);
                    return 0;
                }
            }
            agent_log("display restore %lux%lu: %s; trying again", width, height,
                      g_helper_error ? g_helper_error : "the helper gave no mode");
        }
        Sleep(3000);
    }
    if (!g_stop)
        agent_log("display: nobody signed in, %lux%lu not restored", width, height);
    return 0;
}
