/* ---------- drop helper (runs in the user's session) ---------------------- */

static uint64_t g_drop_bytes;
static unsigned long g_drop_retries;

/* viofs 0.1.302 can present a read in the wrong process, so the read never reaches
 * the device and fails with an in-page error (virtio-win #1633, #1659). Nothing was
 * read, so reading the same offset again is safe. The fix is merged upstream but not
 * released; this can go when a release that has it is pinned. */
#define DROP_READ_RETRIES 50

static int drop_read_failed_in_page(void) {
    DWORD error = GetLastError();
    return error == 999 /* ERROR_SWAPERROR */ || error == 1117 /* ERROR_IO_DEVICE */;
}

/* A plain read/write loop, because CopyFile fails far more often on the same fault.
 * Flushed before it counts, so "dropped" means on disk. */
static int copy_file(const WCHAR *src, const WCHAR *dst) {
    static uint8_t chunk[1 << 20];
    HANDLE in = CreateFileW(src, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                            FILE_FLAG_SEQUENTIAL_SCAN, NULL);
    if (in == INVALID_HANDLE_VALUE)
        return 0;
    HANDLE out = CreateFileW(dst, GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
    if (out == INVALID_HANDLE_VALUE) {
        CloseHandle(in);
        return 0;
    }
    int ok = 1;
    LARGE_INTEGER offset;
    offset.QuadPart = 0;
    for (;;) {
        DWORD got = 0, put = 0;
        int tries = 0;
        while (!ReadFile(in, chunk, sizeof chunk, &got, NULL)) {
            if (!drop_read_failed_in_page() || ++tries > DROP_READ_RETRIES ||
                !SetFilePointerEx(in, offset, NULL, FILE_BEGIN)) {
                ok = 0;
                break;
            }
            g_drop_retries++;
            Sleep(20);
        }
        if (!ok || got == 0)
            break;
        offset.QuadPart += got;
        if (!WriteFile(out, chunk, got, &put, NULL) || put != got) {
            ok = 0;
            break;
        }
        g_drop_bytes += got;
    }
    if (ok && !FlushFileBuffers(out))
        ok = 0;
    DWORD error = GetLastError();
    CloseHandle(in);
    CloseHandle(out);
    SetLastError(error);
    return ok;
}

/* A link in the tree is skipped: its target means nothing here, and following
 * one could reach outside what was dropped. */
static int copy_tree(const WCHAR *src, const WCHAR *dst) {
    DWORD attrs = GetFileAttributesW(src);
    if (attrs == INVALID_FILE_ATTRIBUTES)
        return 0;
    if (attrs & FILE_ATTRIBUTE_REPARSE_POINT)
        return 1;
    if (!(attrs & FILE_ATTRIBUTE_DIRECTORY)) {
        return copy_file(src, dst);
    }
    if (!CreateDirectoryW(dst, NULL))
        return 0;
    static const WCHAR all[] = L"\\*";
    WCHAR pattern[1024];
    if (swprintf(pattern, 1024, L"%ls%ls", src, all) < 0)
        return 0;
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
            swprintf(to, 1024, L"%ls\\%ls", dst, e.cFileName) < 0)
            ok = 0;
        else
            ok = copy_tree(from, to);
    } while (ok && FindNextFileW(find, &e));
    FindClose(find);
    return ok;
}

static void remove_tree(const WCHAR *path) {
    DWORD attrs = GetFileAttributesW(path);
    if (attrs == INVALID_FILE_ATTRIBUTES)
        return;
    if (!(attrs & FILE_ATTRIBUTE_DIRECTORY) || (attrs & FILE_ATTRIBUTE_REPARSE_POINT)) {
        DeleteFileW(path);
        return;
    }
    WCHAR pattern[1024];
    swprintf(pattern, 1024, L"%ls\\*", path);
    WIN32_FIND_DATAW e;
    HANDLE find = FindFirstFileW(pattern, &e);
    if (find != INVALID_HANDLE_VALUE) {
        do {
            if (wcscmp(e.cFileName, L".") != 0 && wcscmp(e.cFileName, L"..") != 0) {
                WCHAR child[1024];
                if (swprintf(child, 1024, L"%ls\\%ls", path, e.cFileName) >= 0)
                    remove_tree(child);
            }
        } while (FindNextFileW(find, &e));
        FindClose(find);
    }
    RemoveDirectoryW(path);
}

/* "name.txt" -> "name (2).txt", as Explorer would. */
static int drop_unique_path(const WCHAR *folder, const WCHAR *item, WCHAR *out, size_t cap) {
    const WCHAR *dot = wcsrchr(item, L'.');
    size_t stem = dot && dot != item ? (size_t)(dot - item) : wcslen(item);
    if (swprintf(out, cap, L"%ls\\%ls", folder, item) < 0)
        return 0;
    for (int n = 2; GetFileAttributesW(out) != INVALID_FILE_ATTRIBUTES; n++) {
        if (n > 999 ||
            swprintf(out, cap, L"%ls\\%.*ls (%d)%ls", folder, (int)stem, item, n, item + stem) < 0)
            return 0;
    }
    return 1;
}

static void helper_print(const char *text) {
    DWORD did = 0;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), text, (DWORD)ovmc_strlen(text), &did, NULL);
}

static int helper_drop(const char *share) {
    /* FOLDERID_Desktop, here so the build needs no knownfolders GUID library. */
    static const GUID desktop_id = {
        0xB4BFCC3A, 0xDB2C, 0x424C, {0xB0, 0x29, 0x7F, 0xE9, 0x9A, 0x87, 0xC6, 0x41}};
    PWSTR desktop = NULL;
    HRESULT found = SHGetKnownFolderPath(&desktop_id, 0, NULL, &desktop);
    if (FAILED(found)) {
        char why[80];
        snprintf(why, sizeof why, "err could not find the Desktop folder (0x%08lx)\n",
                 (unsigned long)found);
        helper_print(why);
        return 1;
    }
    static char input[DROP_ITEMS_MAX * DROP_NAME_MAX];
    HANDLE in = GetStdHandle(STD_INPUT_HANDLE);
    size_t len = 0;
    for (;;) {
        DWORD did = 0;
        if (len >= sizeof input - 1 ||
            !ReadFile(in, input + len, (DWORD)(sizeof input - 1 - len), &did, NULL) || did == 0)
            break;
        len += did;
    }
    input[len] = 0;
    char *line = input;
    while (*line) {
        char *end = line;
        while (*end && *end != '\n')
            end++;
        int more = *end != 0;
        *end = 0;
        char report[DROP_NAME_MAX * 3 + 64];
        WCHAR item[DROP_NAME_MAX], src[600], dst[1024], tmp[600];
        size_t bytes = (size_t)(end - line);
        if (!ovmc_valid_windows_item((const uint8_t *)line, bytes) ||
            utf8_to_wide(line, bytes, item, DROP_NAME_MAX) < 0 ||
            swprintf(src, 600, WIN_VIRTIOFS_DRIVE L"\\drops\\%hs\\%ls", share, item) < 0 ||
            GetFileAttributesW(src) == INVALID_FILE_ATTRIBUTES ||
            !drop_unique_path(desktop, item, dst, 1024)) {
            snprintf(report, sizeof report, "err could not place %s\n", line);
            helper_print(report);
            return 1;
        }
        /* Assembled aside and renamed in, so the Desktop never shows half a tree. */
        swprintf(tmp, 600, L"%ls\\.openvm-drop-%lu", desktop, GetCurrentProcessId());
        g_drop_bytes = 0;
        if (!copy_tree(src, tmp) || !MoveFileW(tmp, dst)) {
            snprintf(report, sizeof report, "err could not copy %s (error %lu)\n", line,
                     (unsigned long)GetLastError());
            remove_tree(tmp); /* never leave half a copy on the user's Desktop */
            helper_print(report);
            return 1;
        }
        char name[DROP_NAME_MAX * 3];
        if (wide_to_utf8(wcsrchr(dst, L'\\') + 1, name, sizeof name) < 0)
            name[0] = 0;
        snprintf(report, sizeof report, "retries %lu\nok %llu %s\n", g_drop_retries,
                 (unsigned long long)g_drop_bytes, name);
        helper_print(report);
        line = more ? end + 1 : end;
    }
    CoTaskMemFree(desktop);
    return 0;
}
