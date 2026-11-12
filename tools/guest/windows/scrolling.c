/* ---------- scroll direction ----------------------------------------------
 * The framework's pointer scrolls the way the fingers move and ignores the Mac's
 * scroll direction, and the host cannot change the events it sends
 * (docs/evidence/scroll-direction-2026-11-12.md). The Mac's default is natural
 * scrolling, so the agent reverses the wheel in the guest: FlipFlopWheel = 1 on
 * every mouse, which also turns sideways scrolling the Mac's way (measured).
 *
 * The value lives in each device's "Device Parameters" key and is read when the
 * device starts. A device whose value was already 1 is left alone, so an ordinary
 * boot restarts nothing; one that changes is restarted at once, as
 * `pnputil /restart-device` does, which applies it without a restart of Windows. */

static DWORD WINAPI scrolling_thread(LPVOID unused) {
    (void)unused;
    /* GUID_DEVCLASS_MOUSE, spelled out so no header has to define it. */
    static const GUID mouse_class = {
        0x4d36e96f, 0xe325, 0x11ce, {0xbf, 0xc1, 0x08, 0x00, 0x2b, 0xe1, 0x03, 0x18}};
    HDEVINFO set = SetupDiGetClassDevsW(&mouse_class, NULL, NULL, DIGCF_PRESENT);
    if (set == INVALID_HANDLE_VALUE) {
        agent_log("scrolling: cannot list the mice (%lu)", GetLastError());
        return 0;
    }
    unsigned seen = 0, changed = 0, failed = 0;
    SP_DEVINFO_DATA dev;
    dev.cbSize = sizeof dev;
    for (DWORD i = 0; SetupDiEnumDeviceInfo(set, i, &dev); i++) {
        seen++;
        HKEY key = SetupDiOpenDevRegKey(set, &dev, DICS_FLAG_GLOBAL, 0, DIREG_DEV,
                                        KEY_QUERY_VALUE | KEY_SET_VALUE);
        if (key == INVALID_HANDLE_VALUE) {
            agent_log("scrolling: mouse %lu: cannot open its parameters (%lu)", i, GetLastError());
            failed++;
            continue;
        }
        DWORD value = 0, size = sizeof value, type = 0;
        int already = RegQueryValueExW(key, L"FlipFlopWheel", NULL, &type, (BYTE *)&value, &size) ==
                          ERROR_SUCCESS &&
                      type == REG_DWORD && value == 1;
        LONG wrote = ERROR_SUCCESS;
        if (!already) {
            DWORD one = 1;
            wrote = RegSetValueExW(key, L"FlipFlopWheel", 0, REG_DWORD, (const BYTE *)&one, sizeof one);
        }
        RegCloseKey(key);
        if (already)
            continue;
        if (wrote != ERROR_SUCCESS) {
            agent_log("scrolling: mouse %lu: cannot write FlipFlopWheel (%ld)", i, (long)wrote);
            failed++;
            continue;
        }
        SP_PROPCHANGE_PARAMS change;
        ovmc_memset_zero(&change, sizeof change);
        change.ClassInstallHeader.cbSize = sizeof change.ClassInstallHeader;
        change.ClassInstallHeader.InstallFunction = DIF_PROPERTYCHANGE;
        change.StateChange = DICS_PROPCHANGE;
        change.Scope = DICS_FLAG_CONFIGSPECIFIC;
        change.HwProfile = 0;
        if (SetupDiSetClassInstallParamsW(set, &dev, &change.ClassInstallHeader, sizeof change) &&
            SetupDiCallClassInstaller(DIF_PROPERTYCHANGE, set, &dev)) {
            changed++;
        } else {
            /* The value is written; the device takes it at its next start. */
            agent_log("scrolling: mouse %lu: restart failed (%lu), applies after a restart", i,
                      GetLastError());
            failed++;
        }
    }
    SetupDiDestroyDeviceInfoList(set);
    agent_log("scrolling: natural on %u mice, %u changed now, %u failed", seen, changed, failed);
    return 0;
}
