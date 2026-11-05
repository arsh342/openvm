/* ---------- clipboard helper (runs in the user's session) ----------------- */

static int helper_fail(void) {
    const char *why = g_helper_error ? g_helper_error : "clipboard unavailable";
    DWORD did = 0;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), why, (DWORD)ovmc_strlen(why), &did, NULL);
    return 1;
}

static int helper_clipboard_read(void) {
    static char text[OVMC_MAX_PAYLOAD / 2];
    size_t len = 0;
    if (!clipboard_read_local(text, sizeof text, &len))
        return helper_fail();
    HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
    size_t sent = 0;
    while (sent < len) {
        DWORD did = 0;
        if (!WriteFile(out, text + sent, (DWORD)(len - sent), &did, NULL) || did == 0)
            return 1;
        sent += did;
    }
    return 0;
}

static int helper_clipboard_write(void) {
    static char text[OVMC_MAX_PAYLOAD / 2 + 1];
    HANDLE in = GetStdHandle(STD_INPUT_HANDLE);
    size_t len = 0;
    for (;;) {
        DWORD did = 0;
        if (len >= sizeof text - 1 ||
            !ReadFile(in, text + len, (DWORD)(sizeof text - 1 - len), &did, NULL) || did == 0)
            break;
        len += did;
    }
    if (!clipboard_write_local(text, len))
        return helper_fail();
    return 0;
}
