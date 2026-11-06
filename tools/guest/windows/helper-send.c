/* ---------- send helper (runs as the user) ----------------------------------
 * Sends files and folders from this guest to the Mac. Started by the SendTo menu (so as the person
 * using Windows) or by the agent on the host's behalf. The set is built under a hidden name in the
 * outbox, marked complete with `.ready` (the top-level names, UTF-8, one per line), and renamed into
 * place, so the host sees one event and never a half-written set.
 *
 * Only plain files and folders go. A link (reparse point) stops the whole send: it could name a file
 * the person never meant to share, and the host refuses such a set anyway. */

#define SEND_MAX_ITEMS 64
#define SEND_MAX_DEPTH 32

static unsigned long g_send_entries;
static const char *g_send_why;

/* A send's failure is shown to the person; started by the agent there is no one to show it to, and
 * the reason goes to stdout instead. */
static int g_send_quiet;

static void send_fail(const WCHAR *path, const char *what) {
    char name[1024] = "";
    if (path != NULL)
        wide_to_utf8(path, name, sizeof name);
    char line[1300];
    snprintf(line, sizeof line, "err %s%s%s\n", what, name[0] ? ": " : "", name);
    helper_print(line);
    g_send_why = what;
}

static int send_tree(const WCHAR *src, const WCHAR *dst, int depth) {
    if (++g_send_entries > 100000) {
        send_fail(src, "too many files");
        return 0;
    }
    DWORD attrs = GetFileAttributesW(src);
    if (attrs == INVALID_FILE_ATTRIBUTES) {
        send_fail(src, "cannot read");
        return 0;
    }
    if (attrs & FILE_ATTRIBUTE_REPARSE_POINT) {
        send_fail(src, "not a plain file or folder");
        return 0;
    }
    if (!(attrs & FILE_ATTRIBUTE_DIRECTORY)) {
        if (!copy_file(src, dst)) {
            send_fail(src, "could not copy");
            return 0;
        }
        return 1;
    }
    if (depth >= SEND_MAX_DEPTH) {
        send_fail(src, "folders nested too deeply");
        return 0;
    }
    if (!CreateDirectoryW(dst, NULL)) {
        send_fail(dst, "cannot create");
        return 0;
    }
    WCHAR pattern[1024];
    if (swprintf(pattern, 1024, L"%ls\\*", src) < 0) {
        send_fail(src, "path too long");
        return 0;
    }
    WIN32_FIND_DATAW e;
    HANDLE find = FindFirstFileW(pattern, &e);
    if (find == INVALID_HANDLE_VALUE)
        return GetLastError() == ERROR_FILE_NOT_FOUND;
    int ok = 1;
    do {
        if (wcscmp(e.cFileName, L".") == 0 || wcscmp(e.cFileName, L"..") == 0)
            continue;
        WCHAR from[1024], to[1024];
        if (swprintf(from, 1024, L"%ls\\%ls", src, e.cFileName) < 0 ||
            swprintf(to, 1024, L"%ls\\%ls", dst, e.cFileName) < 0) {
            send_fail(src, "path too long");
            ok = 0;
        } else {
            ok = send_tree(from, to, depth + 1);
        }
    } while (ok && FindNextFileW(find, &e));
    FindClose(find);
    return ok;
}

/* The last component of a path, without trailing separators. Writes into `out`. */
static int send_base_name(const WCHAR *path, WCHAR *out, size_t cap) {
    size_t n = wcslen(path);
    while (n > 3 && (path[n - 1] == L'\\' || path[n - 1] == L'/'))
        n--;
    size_t start = n;
    while (start > 0 && path[start - 1] != L'\\' && path[start - 1] != L'/')
        start--;
    if (n - start == 0 || n - start >= cap)
        return 0;
    for (size_t i = start; i < n; i++)
        out[i - start] = path[i];
    out[n - start] = 0;
    return 1;
}

static int send_strip_slashes(const WCHAR *path, WCHAR *out, size_t cap) {
    size_t n = wcslen(path);
    while (n > 3 && (path[n - 1] == L'\\' || path[n - 1] == L'/'))
        n--;
    if (n == 0 || n >= cap)
        return 0;
    for (size_t i = 0; i < n; i++)
        out[i] = path[i];
    out[n] = 0;
    return 1;
}

static int helper_send(int count, WCHAR **paths) {
    if (count < 1 || count > SEND_MAX_ITEMS) {
        send_fail(NULL, count < 1 ? "nothing to send" : "too many items (the most is 64)");
        return 1;
    }
    static WCHAR base[SEND_MAX_ITEMS][260];
    static char names[SEND_MAX_ITEMS][800];
    for (int i = 0; i < count; i++) {
        if (!send_base_name(paths[i], base[i], 260) || wide_to_utf8(base[i], names[i], sizeof names[i]) < 0 ||
            !ovmc_valid_windows_item((const uint8_t *)names[i], ovmc_strlen(names[i])) ||
            ovmc_strcmp(names[i], ".ready") == 0) {
            send_fail(paths[i], "cannot send a file with this name");
            return 1;
        }
        for (int j = 0; j < i; j++)
            if (wcsicmp(base[i], base[j]) == 0) {
                send_fail(paths[i], "two items have the same name");
                return 1;
            }
    }

    WCHAR hidden[600], final[600], id[64];
    swprintf(id, 64, L"%lu-%lu", (unsigned long)GetTickCount(), (unsigned long)GetCurrentProcessId());
    swprintf(hidden, 600, WIN_VIRTIOFS_DRIVE L"\\outbox\\.incoming-%ls", id);
    swprintf(final, 600, WIN_VIRTIOFS_DRIVE L"\\outbox\\%ls", id);
    if (!CreateDirectoryW(hidden, NULL)) {
        send_fail(NULL, "cannot use the outbox (is the shared drive up yet?)");
        return 1;
    }

    g_drop_bytes = 0;
    g_send_entries = 0;
    int ok = 1;
    for (int i = 0; i < count && ok; i++) {
        WCHAR src[1024], dst[1024];
        ok = send_strip_slashes(paths[i], src, 1024) &&
             swprintf(dst, 1024, L"%ls\\%ls", hidden, base[i]) >= 0 && send_tree(src, dst, 0);
    }
    if (ok) {
        WCHAR manifest[700];
        swprintf(manifest, 700, L"%ls\\.ready", hidden);
        HANDLE f = CreateFileW(manifest, GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
        ok = f != INVALID_HANDLE_VALUE;
        for (int i = 0; ok && i < count; i++) {
            char line[820];
            int n = snprintf(line, sizeof line, "%s\n", names[i]);
            DWORD did = 0;
            ok = WriteFile(f, line, (DWORD)n, &did, NULL) && did == (DWORD)n;
        }
        if (f != INVALID_HANDLE_VALUE) {
            ok = ok && FlushFileBuffers(f);
            CloseHandle(f);
        }
        if (!ok)
            send_fail(NULL, "cannot write the list of files");
    }
    if (ok && !MoveFileW(hidden, final)) {
        send_fail(NULL, "could not hand the files over");
        ok = 0;
    }
    if (!ok) {
        remove_tree(hidden); /* never leave half a set where the host looks */
        if (!g_send_quiet)
            MessageBoxW(NULL, L"openVM could not send these files to the Mac. Nothing was sent.",
                        L"Send to Mac", MB_OK | MB_ICONWARNING);
        return 1;
    }
    char report[160];
    snprintf(report, sizeof report, "retries %lu\nok %llu sent\n", g_drop_retries,
             (unsigned long long)g_drop_bytes);
    helper_print(report);
    return 0;
}
