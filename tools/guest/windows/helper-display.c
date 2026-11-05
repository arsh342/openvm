/* ---------- display helpers (run in the user's session) ------------------- */

/* Asks for the mode until the driver offers it: the virtio-gpu display event
 * that adds it arrives just after the host reconfigures. */
/* Windows has no documented way to change display scale without a sign-out. These
 * are the types and layouts the Settings app uses, so helper_scale trusts only what
 * the monitor reports afterwards. Scale here is in steps from the recommended value. */
#define DISPLAY_GET_DPI_SCALE ((DISPLAYCONFIG_DEVICE_INFO_TYPE) - 3)
#define DISPLAY_SET_DPI_SCALE ((DISPLAYCONFIG_DEVICE_INFO_TYPE) - 4)
struct dpi_scale_get {
    DISPLAYCONFIG_DEVICE_INFO_HEADER header;
    INT32 min_rel, cur_rel, max_rel;
};
struct dpi_scale_set {
    DISPLAYCONFIG_DEVICE_INFO_HEADER header;
    INT32 scale_rel;
};

static UINT monitor_dpi(void) {
    POINT origin = {0, 0};
    UINT x = 0, y = 0;
    HMONITOR monitor = MonitorFromPoint(origin, MONITOR_DEFAULTTOPRIMARY);
    return GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &x, &y) == S_OK ? x : 0;
}

/* Sets the primary display to `scale` times 100%, and returns the scale it took. */
static unsigned long helper_scale(unsigned long scale, char *why, size_t why_cap) {
    static const int percents[] = {100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500};
    static DISPLAYCONFIG_PATH_INFO path[8];
    static DISPLAYCONFIG_MODE_INFO mode[32];
    UINT32 paths = 8, modes = 32;
    if (QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &paths, path, &modes, mode, NULL) !=
            ERROR_SUCCESS ||
        paths == 0) {
        snprintf(why, why_cap, "Windows reports no active display");
        return 0;
    }
    struct dpi_scale_get get;
    ovmc_memset_zero(&get, sizeof get);
    get.header.type = DISPLAY_GET_DPI_SCALE;
    get.header.size = sizeof get;
    get.header.adapterId = path[0].sourceInfo.adapterId;
    get.header.id = path[0].sourceInfo.id;
    /* The range depends on the mode, and settles just after a mode change. */
    Sleep(1000);
    if (DisplayConfigGetDeviceInfo(&get.header) != ERROR_SUCCESS) {
        snprintf(why, why_cap, "Windows would not report the display scale");
        return 0;
    }
    int want = (int)scale * 100, index = -1, count = (int)(sizeof percents / sizeof percents[0]);
    for (int i = 0; i < count; i++)
        if (percents[i] == want)
            index = i;
    int rel = index + get.min_rel; /* min_rel is 100%, as steps below recommended */
    if (index < 0 || rel > get.max_rel) {
        int top = get.max_rel - get.min_rel;
        snprintf(why, why_cap, "Windows allows at most %d%% at this size",
                 top >= 0 && top < count ? percents[top] : 100);
        return 0;
    }
    struct dpi_scale_set set;
    ovmc_memset_zero(&set, sizeof set);
    set.header.type = DISPLAY_SET_DPI_SCALE;
    set.header.size = sizeof set;
    set.header.adapterId = get.header.adapterId;
    set.header.id = get.header.id;
    set.scale_rel = rel;
    LONG result = DisplayConfigSetDeviceInfo(&set.header);
    if (result != ERROR_SUCCESS) {
        snprintf(why, why_cap, "Windows refused the scale (code %ld)", (long)result);
        return 0;
    }
    UINT dpi = 0;
    for (int i = 0; i < 40; i++) {
        dpi = monitor_dpi();
        if (dpi == 96 * scale)
            return scale;
        Sleep(250);
    }
    snprintf(why, why_cap, "the monitor stayed at %u dpi, not %lu", dpi, 96 * scale);
    return 0;
}

static int helper_display(unsigned long width, unsigned long height, unsigned long scale) {
    DEVMODEW want;
    ovmc_memset_zero(&want, sizeof want);
    want.dmSize = sizeof want;
    want.dmPelsWidth = width;
    want.dmPelsHeight = height;
    want.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT;
    LONG result = DISP_CHANGE_FAILED;
    for (int i = 0; i < 40; i++) {
        result = ChangeDisplaySettingsExW(NULL, &want, NULL, CDS_UPDATEREGISTRY, NULL);
        if (result == DISP_CHANGE_SUCCESSFUL)
            break;
        Sleep(250);
    }
    DEVMODEW now;
    ovmc_memset_zero(&now, sizeof now);
    now.dmSize = sizeof now;
    EnumDisplaySettingsW(NULL, ENUM_CURRENT_SETTINGS, &now);
    char line[200];
    if (result != DISP_CHANGE_SUCCESSFUL) {
        /* What the driver does offer is the only useful clue. */
        DEVMODEW m;
        ovmc_memset_zero(&m, sizeof m);
        m.dmSize = sizeof m;
        DWORD modes = 0, top_w = 0, top_h = 0;
        while (EnumDisplaySettingsW(NULL, modes, &m)) {
            if (m.dmPelsWidth * m.dmPelsHeight > top_w * top_h) {
                top_w = m.dmPelsWidth;
                top_h = m.dmPelsHeight;
            }
            modes++;
        }
        snprintf(
            line, sizeof line,
            "Windows refused %lux%lu (code %ld): holds %lux%lu, offers %lu modes up to %lux%lu",
            width, height, (long)result, (unsigned long)now.dmPelsWidth,
            (unsigned long)now.dmPelsHeight, (unsigned long)modes, (unsigned long)top_w,
            (unsigned long)top_h);
        g_helper_error = line;
        return helper_fail();
    }
    unsigned long held_scale = 0;
    if (scale != 0) {
        held_scale = helper_scale(scale, line, sizeof line);
        if (held_scale == 0) {
            g_helper_error = line;
            return helper_fail();
        }
    }
    int n = snprintf(line, sizeof line, "%lux%lu@%lu", (unsigned long)now.dmPelsWidth,
                     (unsigned long)now.dmPelsHeight, held_scale);
    DWORD did = 0;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), line, (DWORD)n, &did, NULL);
    return 0;
}

/* The primary screen as a 32-bit top-down BMP in the spool. */
/* Plays the tone sound.ps1 wrote, in the session that owns the speakers. */
static int helper_audio_test(void) {
    if (PlaySoundW(L"C:\\openvm\\sound\\tone.wav", NULL, SND_FILENAME | SND_SYNC | SND_NODEFAULT))
        return 0;
    g_helper_error = "Windows could not play the tone";
    return helper_fail();
}

static int helper_capture(void) {
    SetProcessDPIAware();
    int w = GetSystemMetrics(SM_CXSCREEN), h = GetSystemMetrics(SM_CYSCREEN);
    HDC screen = GetDC(NULL);
    HDC mem = CreateCompatibleDC(screen);
    BITMAPINFO info;
    ovmc_memset_zero(&info, sizeof info);
    info.bmiHeader.biSize = sizeof info.bmiHeader;
    info.bmiHeader.biWidth = w;
    info.bmiHeader.biHeight = -h;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    void *bits = NULL;
    HBITMAP bitmap = CreateDIBSection(screen, &info, DIB_RGB_COLORS, &bits, NULL, 0);
    int ok = bitmap != NULL;
    if (ok) {
        HGDIOBJ old = SelectObject(mem, bitmap);
        ok = BitBlt(mem, 0, 0, w, h, screen, 0, 0, SRCCOPY);
        SelectObject(mem, old);
    }
    if (ok) {
        DWORD size = (DWORD)w * (DWORD)h * 4;
        BITMAPFILEHEADER head;
        ovmc_memset_zero(&head, sizeof head);
        head.bfType = 0x4d42;
        head.bfOffBits = sizeof head + sizeof info.bmiHeader;
        head.bfSize = head.bfOffBits + size;
        WCHAR path[WIN_PATH_MAX];
        ok = spool_path("capture.bmp", path, WIN_PATH_MAX);
        HANDLE f = ok ? CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS,
                                    FILE_ATTRIBUTE_NORMAL, NULL)
                      : INVALID_HANDLE_VALUE;
        ok = f != INVALID_HANDLE_VALUE;
        if (ok) {
            DWORD did = 0;
            ok = WriteFile(f, &head, sizeof head, &did, NULL) &&
                 WriteFile(f, &info.bmiHeader, sizeof info.bmiHeader, &did, NULL) &&
                 WriteFile(f, bits, size, &did, NULL);
            CloseHandle(f);
        }
    }
    if (bitmap)
        DeleteObject(bitmap);
    DeleteDC(mem);
    ReleaseDC(NULL, screen);
    if (!ok) {
        g_helper_error = "could not grab the screen";
        return helper_fail();
    }
    return 0;
}
