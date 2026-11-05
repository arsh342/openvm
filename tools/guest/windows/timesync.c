/* timesyncRequest {epochMs, tz?}: the host is the time authority.
 * The guest never runs its own NTP discipline. */
static void handle_timesync(SOCKET fd, const uint8_t *body, const struct ovmc_pair *pairs,
                            size_t count, uint64_t cid) {
    const struct ovmc_pair *ep = ovmc_find(body, pairs, count, "epochMs");
    uint64_t epoch_ms = 0;
    if (ep == NULL || !ovmc_uint_from(body + ep->v0, ep->v1 - ep->v0, &epoch_ms)) {
        emit_error(fd, cid, OVMC_ERR_BAD_PAYLOAD, "timesync needs epochMs");
        return;
    }

    struct ovmc_out w;
    ovmc_out_init(&w);

#ifdef OPENVM_REAL_WIN32
    /* FILETIME counts 100 ns intervals since 1601-01-01; epochMs counts ms
     * since 1970-01-01. The offset between them is a constant. */
    const uint64_t epoch_diff_100ns = 116444736000000000ULL;
    uint64_t ft = epoch_ms * 10000ULL + epoch_diff_100ns;
    FILETIME f;
    f.dwLowDateTime = (DWORD)(ft & 0xffffffffu);
    f.dwHighDateTime = (DWORD)(ft >> 32);
    SYSTEMTIME st;
    if (!FileTimeToSystemTime(&f, &st) || !SetSystemTime(&st)) {
        ovmc_whdr(&w, 5, 2);
        ovmc_wtext(&w, "error");
        ovmc_wtext(&w, "clock set refused (agent needs SeSystemtimePrivilege)");
        ovmc_wtext(&w, "id");
        ovmc_wuint(&w, cid);
        if (w.ok)
            write_reply(fd, T_TIMESYNC_REPLY, w.b, w.n);
        return;
    }
#else
    (void)epoch_ms;
#endif

    /* A zone name is echoed back when the host supplied one; setting the
     * Windows time zone from an IANA name needs a mapping table (Windows uses
     * its own zone keys). This is a minimal mapping for common zones. */
    const struct ovmc_pair *tz = ovmc_find(body, pairs, count, "tz");
    const uint8_t *tztext = NULL;
    size_t tzlen = 0;
    if (tz != NULL && ovmc_text_span(body + tz->v0, tz->v1 - tz->v0, &tztext, &tzlen)) {
        /* Try to apply the timezone on Windows */
        char tz_name[256];
        ovmc_memcpy(tz_name, tztext, tzlen);
        tz_name[tzlen] = '\0';
        const char *tz_error = NULL;
#ifdef OPENVM_REAL_WIN32
        /* Minimal IANA -> Windows timezone mapping */
        static const struct {
            const char *iana;
            const wchar_t *win;
        } tz_map[] = {
            {"UTC", L"UTC"},
            {"GMT", L"GMT Standard Time"},
            {"Europe/London", L"GMT Standard Time"},
            {"Europe/Paris", L"Romance Standard Time"},
            {"Europe/Berlin", L"W. Europe Standard Time"},
            {"Europe/Rome", L"W. Europe Standard Time"},
            {"Europe/Madrid", L"Romance Standard Time"},
            {"Europe/Amsterdam", L"W. Europe Standard Time"},
            {"America/New_York", L"Eastern Standard Time"},
            {"America/Chicago", L"Central Standard Time"},
            {"America/Denver", L"Mountain Standard Time"},
            {"America/Los_Angeles", L"Pacific Standard Time"},
            {"America/Anchorage", L"Alaskan Standard Time"},
            {"Pacific/Honolulu", L"Hawaiian Standard Time"},
            {"Asia/Tokyo", L"Tokyo Standard Time"},
            {"Asia/Shanghai", L"China Standard Time"},
            {"Asia/Singapore", L"Singapore Standard Time"},
            {"Australia/Sydney", L"AUS Eastern Standard Time"},
            {"Australia/Melbourne", L"AUS Eastern Standard Time"},
        };
        const wchar_t *win_tz = NULL;
        for (size_t i = 0; i < sizeof tz_map / sizeof tz_map[0]; i++) {
            if (ovmc_strcmp(tz_name, tz_map[i].iana) == 0) {
                win_tz = tz_map[i].win;
                break;
            }
        }
        if (win_tz == NULL)
            tz_error = "timezone has no Windows mapping in this agent";
        else if (!set_windows_timezone(win_tz))
            tz_error = "could not apply the timezone (tzutil /s failed)";
#endif
        if (tz_error != NULL) {
            ovmc_whdr(&w, 5, 2);
            ovmc_wtext(&w, "error");
            ovmc_wtext(&w, tz_error);
            ovmc_wtext(&w, "id");
            ovmc_wuint(&w, cid);
            if (w.ok)
                write_reply(fd, T_TIMESYNC_REPLY, w.b, w.n);
            return;
        }

        ovmc_whdr(&w, 5, 2);
        ovmc_wtext(&w, "tz");
        ovmc_wtextn(&w, tztext, tzlen);
        ovmc_wtext(&w, "id");
        ovmc_wuint(&w, cid);
    } else {
        ovmc_whdr(&w, 5, 1);
        ovmc_wtext(&w, "id");
        ovmc_wuint(&w, cid);
    }
    if (w.ok)
        write_reply(fd, T_TIMESYNC_REPLY, w.b, w.n);
}
