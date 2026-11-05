/* ---------- audio (22/23) ------------------------------------------------
 * Sound needs nothing from the agent: ALSA plays to the virtio-sound
 * card and the host hears it. The agent reports what the kernel says about that
 * card, and can play a tone so that a person, or a test, has something to observe. */
#ifndef OPENVM_ASOUND
#define OPENVM_ASOUND "/proc/asound"
#endif
#define AUDIO_TEST_SECONDS "3"
#ifndef OPENVM_AUDIO_LOG
#define OPENVM_AUDIO_LOG "/dev/console" /* what a failing tone says is the only clue */
#endif

/* Reads one "key : value" number from a status file. */
static int asound_field(const char *text, const char *key, uint64_t *value) {
    const char *p = strstr(text, key);
    if (p == NULL || (p = strchr(p, ':')) == NULL)
        return 0;
    *value = strtoull(p + 1, NULL, 10);
    return 1;
}

static void audio_response(int fd, uint64_t cid, const char *error) {
    char device[80] = "", path[160], status[1024] = "", params[1024] = "";
    uint64_t rate = 0;
    int running = 0;
    FILE *f = fopen(OPENVM_ASOUND "/card0/id", "r");
    if (f != NULL) {
        if (fgets(device, sizeof device, f) == NULL)
            device[0] = '\0';
        trim_eol(device);
        fclose(f);
    }
    snprintf(path, sizeof path, "%s/card0/pcm0p/sub0/status", OPENVM_ASOUND);
    if ((f = fopen(path, "r")) != NULL) {
        size_t n = fread(status, 1, sizeof status - 1, f);
        status[n] = '\0';
        fclose(f);
    }
    snprintf(path, sizeof path, "%s/card0/pcm0p/sub0/hw_params", OPENVM_ASOUND);
    if ((f = fopen(path, "r")) != NULL) {
        size_t n = fread(params, 1, sizeof params - 1, f);
        params[n] = '\0';
        fclose(f);
    }
    running = strstr(status, "state: RUNNING") != NULL;
    asound_field(params, "rate", &rate);

    struct ovmc_out *w = malloc(sizeof *w);
    if (w == NULL)
        return;
    w->n = 0;
    w->ok = 1;
    ovmc_whdr(w, 5, 3 + (device[0] ? 1 : 0) + (error ? 1 : 0));
    if (device[0]) {
        ovmc_wtext(w, "device");
        ovmc_wtext(w, device);
    }
    ovmc_wtext(w, "running");
    ovmc_wbool(w, running);
    ovmc_wtext(w, "rate");
    ovmc_wuint(w, rate);
    if (error) {
        ovmc_wtext(w, "error");
        ovmc_wtext(w, error);
    }
    ovmc_wtext(w, "id");
    ovmc_wuint(w, cid);
    if (w->ok)
        write_reply(fd, T_AUDIO_REPLY, w->b, w->n);
    free(w);
}

static void handle_audio(int fd, const uint8_t *body, const struct ovmc_pair *pairs, size_t count,
                         uint64_t cid) {
    char op[16];
    if (!text_field(body, pairs, count, "op", op, sizeof op)) {
        audio_response(fd, cid, "audio request has no usable op");
    } else if (strcmp(op, "status") == 0) {
        audio_response(fd, cid, NULL);
    } else if (strcmp(op, "test") == 0) {
        if (access(OPENVM_ASOUND "/card0/id", R_OK) != 0) {
            audio_response(fd, cid, "this guest has no sound card");
        } else if (system("(timeout " AUDIO_TEST_SECONDS
                          " speaker-test -c 2 -r 48000 -t sine -f 440) "
                          ">>" OPENVM_AUDIO_LOG " 2>&1 &") != 0) {
            audio_response(fd, cid, "could not start the test tone");
        } else {
            audio_response(fd, cid, NULL);
        }
    } else {
        audio_response(fd, cid,
                       "audio op must be status or test; Linux guests have sound without enable");
    }
}
