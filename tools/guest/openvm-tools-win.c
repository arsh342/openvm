/* openvm-tools-win.c — the openVM guest agent for Windows.
 *
 * One agent per guest OS, no driver, talks to the virtio-socket
 * device directly, runs as a service. This is the Windows counterpart of
 * tools/guest/openvm-tools.c; both include tools/guest/ovmc_codec.h so the
 * wire format cannot drift between them.
 *
 * Transport. The host opens a connection to vsock port 52 (see
 * Sources/openvmd/GuestBoot.swift). Windows has no AF_VSOCK of its own; the
 * virtio-win "viosock" driver provides one through a Winsock provider, which
 * its INF installs as the auto-start VirtioSocketWSP service. The family
 * number is asked of the driver (IOCTL_GET_AF on \\.\Viosock) and is 40
 * when the driver cannot be asked. The provider can come up after the agent,
 * so a failed socket() or bind() is retried, never fatal.
 *
 * Process model. The agent is the Win32 service OpenVMTools, running as
 * SYSTEM, so the channel is up before anyone logs on and timesync, suspend and
 * the file staging directory have the privileges they need. The clipboard is
 * the exception: session 0 has its own clipboard, so the service runs this
 * same executable in the console user's session (--clipboard-read,
 * --clipboard-write) and talks to it over pipes. `--console` runs the agent in
 * the foreground for debugging. Log: agent.log beside the executable.
 *
 * Build (from macOS): tools/build/build-windows-agent.sh, which cross-compiles with
 * zig's bundled mingw-w64 headers and ARM64 import libraries. The syntax-check
 * build (tools/test/test-windows-agent.sh) still type-checks the codec and handlers
 * without any Windows headers.
 *
 */

#include "ovmc_codec.h"

/* Two build modes:
 *
 *   real Windows build   _WIN32 defined, headers available. Full agent.
 *   syntax check (macOS)  OPENVM_SYNTAX_CHECK defined. The codec and every
 *                         message handler are type-checked against minimal
 *                         declarations of the Win32 surface they touch, so a
 *                         regression is caught by tools/test/test-windows-agent.sh
 *                         without a Windows SDK or a Windows machine.
 *
 * The syntax-check mode never executes anything: main() returns immediately.
 */
#if defined(_WIN32) && !defined(OPENVM_SYNTAX_CHECK)
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <wtsapi32.h>
#include <winspool.h>
#include <mmsystem.h>
#include <shellscalingapi.h>
#include <shlobj.h>
#include <userenv.h>
#include <setupapi.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define OPENVM_REAL_WIN32 1
#else
/* Minimal declarations of exactly what this file uses. Types match the Win32
 * ABI on arm64 (LP64: DWORD is 32-bit, HANDLE/HGLOBAL are pointers). */
typedef int SOCKET;
typedef unsigned long DWORD;
typedef void *HANDLE;
typedef void *HGLOBAL;
typedef unsigned short WORD;
typedef int BOOL;
typedef unsigned int UINT;
typedef long LONG;
typedef wchar_t WCHAR;
typedef WCHAR *LPWSTR;
typedef const WCHAR *LPCWSTR;
struct sockaddr;
#define INVALID_SOCKET (-1)
#define SOCKET_ERROR (-1)
#define CP_UTF8 65001
#define CF_UNICODETEXT 13
#define GMEM_MOVEABLE 0x0002
#define TRUE 1
#define FALSE 0
SOCKET socket(int, int, int);
int bind(SOCKET, const struct sockaddr *, int);
int listen(SOCKET, int);
SOCKET accept(SOCKET, struct sockaddr *, int *);
int closesocket(SOCKET);
int send(SOCKET, const char *, int, int);
int recv(SOCKET, char *, int, int);
int WSAStartup(WORD, void *);
int WSACleanup(void);
BOOL OpenClipboard(HANDLE);
BOOL CloseClipboard(void);
BOOL EmptyClipboard(void);
HANDLE GetClipboardData(UINT);
HANDLE SetClipboardData(UINT, HANDLE);
HGLOBAL GlobalAlloc(UINT, size_t);
HGLOBAL GlobalFree(HGLOBAL);
void *GlobalLock(HGLOBAL);
BOOL GlobalUnlock(HGLOBAL);
int MultiByteToWideChar(UINT, DWORD, const char *, int, LPWSTR, int);
int WideCharToMultiByte(UINT, DWORD, LPCWSTR, int, char *, int, const char *, BOOL *);
size_t wcslen(const WCHAR *);
void *memset(void *, int, size_t);
void *malloc(size_t);
void free(void *);
int main(int, char **);

/* File service (message types 10/11). Only the Win32 calls the staging
 * directory touches are declared here. */
typedef long long LONGLONG;
typedef struct {
    LONGLONG QuadPart;
} LARGE_INTEGER;
typedef struct {
    DWORD dwLowDateTime;
    DWORD dwHighDateTime;
} FILETIME;
typedef struct {
    WORD wYear, wMonth, wDayOfWeek, wDay, wHour, wMinute, wSecond, wMilliseconds;
} SYSTEMTIME;
typedef struct {
    unsigned short wVersion;
    char _pad[400];
} WSADATA;
#define SOCK_STREAM 1
#define MAKEWORD(a, b) ((WORD)(((a) & 0xff) | (((b) & 0xff) << 8)))
BOOL FileTimeToSystemTime(const FILETIME *, SYSTEMTIME *);
BOOL SetSystemTime(const SYSTEMTIME *);
#define GENERIC_READ 0x80000000
#define GENERIC_WRITE 0x40000000
#define FILE_SHARE_READ 0x00000001
#define FILE_SHARE_WRITE 0x00000002
#define CREATE_NEW 1
#define OPEN_EXISTING 3
#define FILE_ATTRIBUTE_NORMAL 0x00000080
#define FILE_FLAG_OPEN_REPARSE_POINT 0x00200000
#define FILE_FLAG_BACKUP_SEMANTICS 0x02000000
#define MOVEFILE_REPLACE_EXISTING 0x00000001
#define FILE_BEGIN 0
#define ERROR_FILE_NOT_FOUND 2
#define INVALID_HANDLE_VALUE ((HANDLE)(LONGLONG) - 1)
HANDLE CreateFileW(LPCWSTR, DWORD, DWORD, void *, DWORD, DWORD, HANDLE);
BOOL CloseHandle(HANDLE);
BOOL ReadFile(HANDLE, void *, DWORD, DWORD *, void *);
BOOL WriteFile(HANDLE, const void *, DWORD, DWORD *, void *);
BOOL GetFileSizeEx(HANDLE, LARGE_INTEGER *);
BOOL SetFilePointerEx(HANDLE, LARGE_INTEGER, LARGE_INTEGER *, DWORD);
BOOL FlushFileBuffers(HANDLE);
BOOL MoveFileExW(LPCWSTR, LPCWSTR, DWORD);
BOOL DeleteFileW(LPCWSTR);
BOOL CreateDirectoryW(LPCWSTR, void *);
DWORD GetTempPathW(DWORD, LPWSTR);
DWORD GetLastError(void);

/* Timezone API (for SetDynamicTimeZoneInformation) */
typedef void *HMODULE;
HMODULE GetModuleHandleW(LPCWSTR);
void *GetProcAddress(HMODULE, const char *);
typedef int BOOLEAN;
#define WINAPI
int wcscpy_s(WCHAR *, size_t, const WCHAR *);

/* Dynamic timezone information structure (simplified) */
typedef struct {
    LONG Bias;
    WCHAR StandardName[32];
    SYSTEMTIME StandardDate;
    LONG StandardBias;
    WCHAR DaylightName[32];
    SYSTEMTIME DaylightDate;
    LONG DaylightBias;
    WCHAR TimeZoneKeyName[128];
    BOOLEAN DynamicDaylightTimeDisabled;
} DYNAMIC_TIME_ZONE_INFORMATION;
typedef BOOL (*SetDynamicTimeZoneInformation_t)(const DYNAMIC_TIME_ZONE_INFORMATION *);

/* Process API (tzutil for the time zone). */
typedef struct {
    DWORD cb;
    char _pad[100];
} STARTUPINFOW;
typedef struct {
    HANDLE hProcess;
    HANDLE hThread;
    DWORD dwProcessId;
    DWORD dwThreadId;
} PROCESS_INFORMATION;
#define CREATE_NO_WINDOW 0x08000000
#define WAIT_OBJECT_0 0
BOOL CreateProcessW(LPCWSTR, LPWSTR, void *, void *, BOOL, DWORD, void *, LPCWSTR, STARTUPINFOW *,
                    PROCESS_INFORMATION *);
DWORD WaitForSingleObject(HANDLE, DWORD);
BOOL GetExitCodeProcess(HANDLE, DWORD *);
#endif

#ifdef OPENVM_REAL_WIN32
static void agent_log(const char *fmt, ...);
#endif

#include "windows/transport.c"
#include "windows/state.c"
#include "windows/files.c"
#include "windows/handlers.c"
#include "windows/timesync.c"
#include "windows/suspend.c"
#include "windows/drag.c"
#include "windows/printers.c"
#include "windows/audio.c"
#include "windows/display.c"
#include "windows/shares.c"
#include "windows/connection.c"

#ifdef OPENVM_REAL_WIN32
#include "windows/log.c"
#include "windows/scrolling.c"
#include "windows/display-restore.c"
#include "windows/listener.c"
#include "windows/service.c"
#include "windows/helper-clipboard.c"
#include "windows/helper-printing.c"
#include "windows/helper-drop.c"
#include "windows/helper-send.c"
#include "windows/helper-display.c"
#endif

int main(int argc, char **argv) {
#ifdef OPENVM_REAL_WIN32
    if (argc == 3 && ovmc_strcmp(argv[1], "--drop") == 0)
        return helper_drop(argv[2]);
    if (argc >= 3 && (ovmc_strcmp(argv[1], "--send") == 0 || ovmc_strcmp(argv[1], "--send-quiet") == 0)) {
        /* Wide arguments: a name outside the ANSI code page would not survive argv. */
        int wide_count = 0;
        WCHAR **wide = CommandLineToArgvW(GetCommandLineW(), &wide_count);
        if (wide == NULL || wide_count < 3)
            return 1;
        g_send_quiet = ovmc_strcmp(argv[1], "--send-quiet") == 0;
        return helper_send(wide_count - 2, wide + 2);
    }
    if (argc == 5 && ovmc_strcmp(argv[1], "--display") == 0) {
        /* The scale is read from the monitor, which only tells an aware process. */
        SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        return helper_display(strtoul(argv[2], NULL, 10), strtoul(argv[3], NULL, 10),
                              strtoul(argv[4], NULL, 10));
    }
    if (argc == 2 && ovmc_strcmp(argv[1], "--capture") == 0)
        return helper_capture();
    if (argc == 2 && ovmc_strcmp(argv[1], "--audio-test") == 0)
        return helper_audio_test();
    if (argc == 3 && ovmc_strcmp(argv[1], "--default-printer") == 0)
        return helper_default_printer(argv[2]);
    if (argc == 3 && ovmc_strcmp(argv[1], "--print-test") == 0)
        return helper_print_test(argv[2]);
    if (argc == 2 && ovmc_strcmp(argv[1], "--clipboard-read") == 0)
        return helper_clipboard_read();
    if (argc == 2 && ovmc_strcmp(argv[1], "--clipboard-write") == 0)
        return helper_clipboard_write();

    log_init();
    if (argc == 2 && ovmc_strcmp(argv[1], "--console") == 0) {
        g_console = 1;
        return run_agent();
    }
    if (argc != 1) {
        fprintf(stderr, "usage: openvm-tools-win [--console]\n"
                        "  no argument: run as the OpenVMTools service\n");
        return 2;
    }
    static WCHAR service_name[] = SERVICE_NAME_W;
    SERVICE_TABLE_ENTRYW table[] = {{service_name, service_main}, {NULL, NULL}};
    if (!StartServiceCtrlDispatcherW(table)) {
        if (GetLastError() == ERROR_FAILED_SERVICE_CONTROLLER_CONNECT) {
            /* Started from a prompt, not by the service manager. */
            g_console = 1;
            return run_agent();
        }
        return 1;
    }
    return 0;
#else
    /* Host build: this file is compiled on macOS only to type-check the codec
     * and the handlers. There is no vsock transport here. */
    (void)argc;
    (void)argv;
    return 0;
#endif
}
