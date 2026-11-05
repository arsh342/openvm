/* ---------- service ------------------------------------------------------- */

#define SERVICE_NAME_W L"OpenVMTools"
static SERVICE_STATUS_HANDLE g_service;
static SERVICE_STATUS g_service_status;

static void service_report(DWORD state, DWORD exit_code) {
    g_service_status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
    g_service_status.dwCurrentState = state;
    g_service_status.dwControlsAccepted = state == SERVICE_RUNNING
                                              ? SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN
#ifdef OPENVM_AGENT_TRACE
                                                    | SERVICE_ACCEPT_POWEREVENT
#endif
                                              : 0;
    g_service_status.dwWin32ExitCode = exit_code;
    g_service_status.dwWaitHint = state == SERVICE_STOP_PENDING ? 5000 : 0;
    SetServiceStatus(g_service, &g_service_status);
}

static DWORD WINAPI service_control(DWORD control, DWORD type, LPVOID data, LPVOID context) {
    (void)context;
#ifndef OPENVM_AGENT_TRACE
    (void)type;
    (void)data;
#endif
    switch (control) {
    case SERVICE_CONTROL_STOP:
    case SERVICE_CONTROL_SHUTDOWN:
        InterlockedExchange(&g_stop, 1);
        service_report(SERVICE_STOP_PENDING, NO_ERROR);
        /* Unblocks accept(); the loop sees g_stop and returns. */
        if (g_listen != INVALID_SOCKET)
            closesocket(g_listen);
        return NO_ERROR;
#ifdef OPENVM_AGENT_TRACE
    case SERVICE_CONTROL_POWEREVENT:
        if (type == PBT_POWERSETTINGCHANGE) {
            const POWERBROADCAST_SETTING *set = data;
            agent_log("trace: display state %lu (0 off, 1 on, 2 dimmed)",
                      set->DataLength >= 4 ? *(const unsigned long *)set->Data : 99ul);
        } else {
            agent_log("trace: power event %lu", (unsigned long)type);
        }
        return NO_ERROR;
#endif
    case SERVICE_CONTROL_INTERROGATE:
        return NO_ERROR;
    default:
        return ERROR_CALL_NOT_IMPLEMENTED;
    }
}

static void WINAPI service_main(DWORD argc, LPWSTR *argv) {
    (void)argc;
    (void)argv;
    g_service = RegisterServiceCtrlHandlerExW(SERVICE_NAME_W, service_control, NULL);
    if (g_service == NULL)
        return;
    service_report(SERVICE_RUNNING, NO_ERROR);
#ifdef OPENVM_AGENT_TRACE
    static const GUID console_display = {
        0x6fe69556, 0x704a, 0x47a0, {0x8f, 0x24, 0xc2, 0x8d, 0x93, 0x6f, 0xda, 0x47}};
    RegisterPowerSettingNotification(g_service, &console_display, DEVICE_NOTIFY_SERVICE_HANDLE);
#endif
    int rc = run_agent();
    service_report(SERVICE_STOPPED, rc == 0 ? NO_ERROR : ERROR_SERVICE_SPECIFIC_ERROR);
}
