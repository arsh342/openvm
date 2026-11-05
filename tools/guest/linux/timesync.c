/* ---------- timesync: adopt the host wall clock -------------
 * daemon sends {epochMs}; the guest clock is host-driven, never NTP-set.
 * The agent runs as root under its OpenRC service, so clock_settime is legal;
 * elsewhere (like the unit harness) a failure surfaces as a clock error. */
static void timesync_response(int fd, uint64_t cid, const char *error, const char *tz) {
    struct ovmc_out *w = malloc(sizeof *w); /* heap: avoids a 1 MiB stack frame on
                                          worker threads (handle_file does same) */
    if (!w)
        return;
    w->n = 0;
    w->ok = 1;
    ovmc_whdr(w, 5, error ? 2 : (tz ? 2 : 1));
    if (error) {
        ovmc_wtext(w, "error");
        ovmc_wtext(w, error);
    } else if (tz) {
        ovmc_wtext(w, "tz");
        ovmc_wtext(w, tz);
    }
    ovmc_wtext(w, "id");
    ovmc_wuint(w, cid);
    if (w->ok)
        write_reply(fd, T_TIMESYNC_REPLY, w->b, w->n);
    free(w);
}

/* Zone names mirror the host rule: slash-separated components of
 * [A-Za-z0-9_+-], each non-empty and starting with a letter. Nothing may
 * escape the zoneinfo root. */
static int valid_timezone(const char *tz) {
    size_t n = strlen(tz);
    if (n == 0 || n > 64)
        return 0;
    size_t i = 0;
    for (;;) {
        size_t start = i;
        while (i < n && tz[i] != '/')
            i++;
        size_t len = i - start;
        if (len == 0)
            return 0;
        char first = tz[start];
        if (!((first >= 'A' && first <= 'Z') || (first >= 'a' && first <= 'z')))
            return 0;
        for (size_t j = start; j < i; j++) {
            char c = tz[j];
            if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
                  c == '_' || c == '+' || c == '-'))
                return 0;
        }
        if (i == n)
            return 1;
        i++; /* skip '/' */
        if (i == n)
            return 0; /* trailing slash */
    }
}

/* Points the guest's local time at the requested zone. The zoneinfo file must
 * exist; /etc/localtime becomes a symlink into it. */
static int apply_timezone(const char *tz, char *reason, size_t cap) {
    char zone[160];
    snprintf(zone, sizeof zone, "%s/%s", OPENVM_TZINFO_DIR, tz);
    struct stat st;
    if (stat(zone, &st) != 0) {
        snprintf(reason, cap, "unknown timezone %s", tz);
        return 0;
    }
    if (unlink(OPENVM_LOCALTIME_PATH) != 0 && errno != ENOENT) {
        snprintf(reason, cap, "could not set guest timezone (%s)", strerror(errno));
        return 0;
    }
    if (symlink(zone, OPENVM_LOCALTIME_PATH) != 0) {
        snprintf(reason, cap, "could not set guest timezone (%s)", strerror(errno));
        return 0;
    }
    return 1;
}

static void handle_timesync(int fd, const uint8_t *body, const struct ovmc_pair *pairs,
                            size_t count, uint64_t cid) {
    const struct ovmc_pair *ms_pair = find_pair(body, pairs, count, "epochMs");
    uint64_t ms;
    if (!ms_pair || !ovmc_uint_from(body + ms_pair->v0, ms_pair->v1 - ms_pair->v0, &ms) ||
        ms > UINT64_C(253402300799000)) { /* sanity cap: year 9999 */
        timesync_response(fd, cid, "timesync request has no usable epochMs", NULL);
        return;
    }
    /* An optional timezone rides along: the host is the authority for both the
     * clock and the zone. The zone is applied before the clock
     * so a zone error is reported as such even where the clock cannot be set. */
    char tz[72];
    const char *zone = NULL;
    const struct ovmc_pair *tz_pair = find_pair(body, pairs, count, "tz");
    if (tz_pair) {
        const uint8_t *t = NULL;
        size_t tlen = 0;
        if (!ovmc_text_span(body + tz_pair->v0, tz_pair->v1 - tz_pair->v0, &t, &tlen) ||
            tlen == 0 || tlen >= sizeof tz) {
            timesync_response(fd, cid, "timesync request has an unusable tz", NULL);
            return;
        }
        memcpy(tz, t, tlen);
        tz[tlen] = '\0';
        if (!valid_timezone(tz)) {
            timesync_response(fd, cid, "invalid timezone name", NULL);
            return;
        }
        char reason[96];
        if (!apply_timezone(tz, reason, sizeof reason)) {
            timesync_response(fd, cid, reason, NULL);
            return;
        }
        fprintf(stderr, "openvm-tools: guest timezone applied (%s)\n", tz);
        zone = tz;
    }
    struct timespec ts;
    ts.tv_sec = (time_t)(ms / 1000);
    ts.tv_nsec = (long)((ms % 1000) * 1000000L);
    if (clock_settime(CLOCK_REALTIME, &ts) < 0) {
        char reason[96];
        snprintf(reason, sizeof reason, "could not set the guest clock (%s)", strerror(errno));
        timesync_response(fd, cid, reason, NULL);
        return;
    }
    fprintf(stderr, "openvm-tools: host clock applied (%llu ms)\n", (unsigned long long)ms);
    timesync_response(fd, cid, NULL, zone);
}
