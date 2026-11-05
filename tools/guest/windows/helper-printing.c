/* ---------- printing helpers (run in the user's session) ------------------ */

static int widen_arg(const char *in, WCHAR *out, size_t cap) {
    if (!valid_printer_name(in) || ovmc_strlen(in) >= cap)
        return 0;
    size_t i = 0;
    for (; in[i]; i++)
        out[i] = (WCHAR)(unsigned char)in[i];
    out[i] = 0;
    return 1;
}

/* Follows the host's default. Windows otherwise moves the default to the last
 * printer used unless this per-user switch is on. */
static int helper_default_printer(const char *name) {
    WCHAR printer[PRINTER_NAME_MAX];
    if (!widen_arg(name, printer, PRINTER_NAME_MAX))
        return 1;
    DWORD legacy = 1;
    RegSetKeyValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows NT\\CurrentVersion\\Windows",
                    L"LegacyDefaultPrinterMode", REG_DWORD, &legacy, sizeof legacy);
    if (!SetDefaultPrinterW(printer)) {
        g_helper_error = "SetDefaultPrinter refused the queue";
        return helper_fail();
    }
    return 0;
}

/* One GDI page: the route a desktop application's print takes. */
static int helper_print_test(const char *name) {
    WCHAR printer[PRINTER_NAME_MAX];
    if (!widen_arg(name, printer, PRINTER_NAME_MAX))
        return 1;
    HDC dc = CreateDCW(L"WINSPOOL", printer, NULL, NULL);
    if (dc == NULL) {
        g_helper_error = "could not open the queue";
        return helper_fail();
    }
    DOCINFOW doc;
    ovmc_memset_zero(&doc, sizeof doc);
    doc.cbSize = sizeof doc;
    doc.lpszDocName = L"openVM test page";
    static const WCHAR line[] = L"openVM test page from a Windows guest";
    int ok = StartDocW(dc, &doc) > 0 && StartPage(dc) > 0 &&
             TextOutW(dc, 300, 300, line, (int)(sizeof line / sizeof line[0]) - 1) &&
             EndPage(dc) > 0 && EndDoc(dc) > 0;
    DeleteDC(dc);
    if (!ok) {
        g_helper_error = "the spooler refused the test page";
        return helper_fail();
    }
    return 0;
}
