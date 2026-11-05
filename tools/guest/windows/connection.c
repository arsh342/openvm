/* ---------- connection loop ---------------------------------------------- */

static uint8_t g_ring[OVMC_MAX_PAYLOAD];

static void serve_connection(SOCKET fd) {
    uint8_t head[OVMC_FRAME_HEADER];
    for (;;) {
        if (sock_recv_all(fd, head, OVMC_FRAME_HEADER) != 0)
            return;
        struct ovmc_header h = ovmc_parse_header(head);
        if (!h.ok)
            return; /* receiver stop rule: close, no resync */

        size_t have = 0;
        while (have < h.length) {
            if (sock_recv_all(fd, g_ring + have, h.length - have) != 0)
                return;
            have = h.length;
        }

        struct ovmc_pair pairs[OVMC_MAX_PAIRS];
        uint64_t cid = 0;
        long npairs = ovmc_walk_map(g_ring, h.length, pairs, OVMC_MAX_PAIRS, &cid);
        if (npairs < 0) {
            emit_error(fd, 0, OVMC_ERR_BAD_PAYLOAD, "body is not a CBOR map");
            return;
        }

        switch (h.type) {
        case T_HELLO:
            handle_hello(fd, cid);
            break;
        case T_ECHO_REQUEST:
            handle_echo(fd, g_ring, h.length, cid);
            break;
        case T_CLIPBOARD_REQUEST:
            handle_clipboard(fd, g_ring, pairs, (size_t)npairs, cid);
            break;
        case T_TIMESYNC_REQUEST:
            handle_timesync(fd, g_ring, pairs, (size_t)npairs, cid);
            break;
        case T_SUSPEND_REQUEST:
            handle_suspend(fd, g_ring, pairs, (size_t)npairs, cid);
            break;
        case T_FILE_REQUEST:
            handle_file(fd, g_ring, pairs, (size_t)npairs, cid);
            break;
        case T_SHARED_REQUEST:
            handle_shared(fd, g_ring, pairs, (size_t)npairs, cid);
            break;
        case T_DRAG_REQUEST:
            handle_drag(fd, g_ring, pairs, (size_t)npairs, cid);
            break;
        case T_PRINTER_REQUEST:
            handle_printer(fd, g_ring, pairs, (size_t)npairs, cid);
            break;
        case T_AUDIO_REQUEST:
            handle_audio(fd, g_ring, pairs, (size_t)npairs, cid);
            break;
        case T_DISPLAY_REQUEST:
            handle_display(fd, g_ring, pairs, (size_t)npairs, cid);
            break;
        case T_HELLO_REPLY:
        case T_ECHO_REPLY:
        case T_ERROR:
        case T_CLIPBOARD_REPLY:
        case T_TIMESYNC_REPLY:
        case T_SUSPEND_REPLY:
        case T_FILE_REPLY:
        case T_SHARED_REPLY:
        case T_DRAG_REPLY:
        case T_PRINTER_REPLY:
        case T_AUDIO_REPLY:
        case T_DISPLAY_REPLY:
            /* Only the opener drives; a reply sent to the answering side is
             * an unknownType error (docs/guest-protocol.md frame rule 5). */
            emit_error(fd, cid, OVMC_ERR_UNKNOWN_TYPE, "reply type sent to the guest");
            return;
        default:
            emit_error(fd, cid, OVMC_ERR_UNKNOWN_TYPE, "unknown message type");
            break;
        }
    }
}
