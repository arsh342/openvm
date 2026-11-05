/* ---------- audio (22/23) ------------------------------------------------
 * virtio-win has no driver for the sound device. The only ones that exist are
 * test-signed, so sound stays off until the owner of this guest turns it on:
 * tools/windows/sound.ps1 does the work, and says what state the guest is in.
 * Windows has no cheap answer to "is something playing", so `running` is left out
 * rather than guessed. */
static void audio_reply(SOCKET fd, uint64_t cid, const char *state, const char *device,
                        const char *error) {
    static struct ovmc_out w;
    ovmc_out_init(&w);
    ovmc_whdr(&w, 5, 1 + (state ? 1 : 0) + (device && device[0] ? 1 : 0) + (error ? 1 : 0));
    if (state) {
        ovmc_wtext(&w, "state");
        ovmc_wtext(&w, state);
    }
    if (device && device[0]) {
        ovmc_wtext(&w, "device");
        ovmc_wtext(&w, device);
    }
    if (error) {
        ovmc_wtext(&w, "error");
        ovmc_wtext(&w, error);
    }
    ovmc_wtext(&w, "id");
    ovmc_wuint(&w, cid);
    if (w.ok)
        write_reply(fd, T_AUDIO_REPLY, w.b, w.n);
}

#ifdef OPENVM_REAL_WIN32
/* Runs sound.ps1. `state` gets the word before the | on its last line, `detail`
 * what follows, in ASCII because it goes out as CBOR text. */
static int sound_script(const char *op, DWORD timeout_ms, char *state, size_t state_cap,
                        char *detail, size_t detail_cap) {
    static char out[4096];
    WCHAR cmd[256];
    state[0] = detail[0] = '\0';
    swprintf(cmd, sizeof cmd / sizeof cmd[0],
             L"powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass "
             L"-File C:\\openvm\\sound\\sound.ps1 -Op %hs",
             op);
    int ok = run_script(cmd, out, sizeof out, timeout_ms);
    size_t end = 0;
    while (out[end])
        end++;
    while (end > 0 && (out[end - 1] == '\r' || out[end - 1] == '\n' || out[end - 1] == ' '))
        out[--end] = '\0';
    size_t line = end;
    while (line > 0 && out[line - 1] != '\n')
        line--;
    size_t bar = line;
    while (bar < end && out[bar] != '|')
        bar++;
    if (bar == end) {
        snprintf(detail, detail_cap, "%s", out[line] ? out + line : "sound.ps1 did not run");
        snprintf(state, state_cap, "failed");
        return 0;
    }
    size_t k = 0;
    for (size_t i = line; i < bar && k + 1 < state_cap; i++)
        state[k++] = out[i];
    state[k] = '\0';
    k = 0;
    for (size_t i = bar + 1; i < end && k + 1 < detail_cap; i++)
        detail[k++] = out[i] >= 0x20 && out[i] < 0x7f ? out[i] : '?';
    detail[k] = '\0';
    return ok;
}
#endif

#ifdef OPENVM_REAL_WIN32
/* Status must be quick. It holds the agent, and PowerShell can take over ten seconds
 * to start on a guest that has just booted, so it reads what sound.ps1 leaves. */
static void sound_status(char *state, size_t state_cap, char *detail, size_t detail_cap) {
    detail[0] = '\0';
    SERVICE_STATUS status;
    int running = 0;
    SC_HANDLE manager = OpenSCManagerW(NULL, NULL, SC_MANAGER_CONNECT);
    SC_HANDLE service = manager ? OpenServiceW(manager, L"viosnd", SERVICE_QUERY_STATUS) : NULL;
    if (service) {
        running = QueryServiceStatus(service, &status) && status.dwCurrentState == SERVICE_RUNNING;
        CloseServiceHandle(service);
    }
    if (manager)
        CloseServiceHandle(manager);
    if (running) {
        snprintf(state, state_cap, "on");
        snprintf(detail, detail_cap, "XCB VirtIO Audio Device");
        return;
    }
    HANDLE failed = CreateFileW(L"C:\\openvm\\sound\\sound.failed", GENERIC_READ, FILE_SHARE_READ,
                                NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (failed != INVALID_HANDLE_VALUE) {
        DWORD got = 0;
        ReadFile(failed, detail, (DWORD)detail_cap - 1, &got, NULL);
        CloseHandle(failed);
        for (DWORD i = 0; i < got; i++)
            if ((uint8_t)detail[i] < 0x20 || (uint8_t)detail[i] >= 0x7f)
                detail[i] = ' ';
        detail[got] = '\0';
        snprintf(state, state_cap, "failed");
        return;
    }
    DWORD pending = GetFileAttributesW(L"C:\\openvm\\sound\\sound.pending");
    snprintf(state, state_cap, pending != INVALID_FILE_ATTRIBUTES ? "pending" : "off");
}
#endif

static void handle_audio(SOCKET fd, const uint8_t *body, const struct ovmc_pair *pairs,
                         size_t count, uint64_t cid) {
    const struct ovmc_pair *op_pair = ovmc_find(body, pairs, count, "op");
    const uint8_t *op_text = NULL;
    size_t op_len = 0;
    char op[16];
    if (op_pair == NULL ||
        !ovmc_text_span(body + op_pair->v0, op_pair->v1 - op_pair->v0, &op_text, &op_len) ||
        op_len >= sizeof op) {
        audio_reply(fd, cid, NULL, NULL, "audio op must be status, test, enable or disable");
        return;
    }
    ovmc_memcpy(op, op_text, op_len);
    op[op_len] = '\0';
    int is_status = ovmc_strcmp(op, "status") == 0, is_test = ovmc_strcmp(op, "test") == 0;
    int is_change = ovmc_strcmp(op, "enable") == 0 || ovmc_strcmp(op, "disable") == 0;
    if (!is_status && !is_test && !is_change) {
        audio_reply(fd, cid, NULL, NULL, "audio op must be status, test, enable or disable");
        return;
    }
#ifdef OPENVM_REAL_WIN32
    char state[16], detail[256];
    int ok = 1;
    if (is_change)
        ok = sound_script(op, 110000, state, sizeof state, detail, sizeof detail);
    else
        sound_status(state, sizeof state, detail, sizeof detail);
    if (!ok || ovmc_strcmp(state, "failed") == 0) {
        audio_reply(fd, cid, state, NULL, detail[0] ? detail : "sound.ps1 failed");
        return;
    }
    if (is_test) {
        uint8_t said[160];
        size_t got = 0;
        if (ovmc_strcmp(state, "on") != 0) {
            audio_reply(fd, cid, state, NULL, "sound is not on in this guest");
            return;
        }
        g_helper_error = NULL;
        if (!run_in_user_session(L"--audio-test", NULL, 0, said, sizeof said, &got)) {
            audio_reply(fd, cid, state, detail,
                        g_helper_error ? g_helper_error : "the tone did not play");
            return;
        }
    }
    audio_reply(fd, cid, state, ovmc_strcmp(state, "on") == 0 ? detail : NULL, NULL);
#else
    audio_reply(fd, cid, "off", NULL, NULL);
#endif
}
