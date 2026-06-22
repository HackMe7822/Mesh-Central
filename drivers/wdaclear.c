/*
 * wdaclear.c - User-mode service that calls IOCTL_CAPTURE_GET_FRAME every 100ms.
 *
 * Kernel system threads have no win32k desktop context, so the background
 * thread inside the driver cannot enumerate windows. This user-mode service
 * runs in a proper Win32 thread context where NtUserBuildHwndList works.
 *
 * Register as a service:
 *   sc.exe create wdaclear type= own start= auto binPath= "C:\wdaclear.exe"
 *   sc.exe start wdaclear
 */

#include <windows.h>
#include <stdio.h>

#define FILE_DEVICE_UNKNOWN 0x00000022
#define METHOD_BUFFERED     0
#define FILE_ANY_ACCESS     0
#ifndef CTL_CODE
#define CTL_CODE(d,f,m,a) (((d)<<16)|((a)<<14)|((f)<<2)|(m))
#endif
#define IOCTL_CAPTURE_GET_FRAME \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x801, METHOD_BUFFERED, FILE_ANY_ACCESS)

static SERVICE_STATUS        g_Status;
static SERVICE_STATUS_HANDLE g_hStatus;
static HANDLE                g_StopEvent;

static void ReportStatus(DWORD state, DWORD exitCode, DWORD wait)
{
    g_Status.dwCurrentState  = state;
    g_Status.dwWin32ExitCode = exitCode;
    g_Status.dwWaitHint      = wait;
    if (state == SERVICE_START_PENDING)
        g_Status.dwControlsAccepted = 0;
    else
        g_Status.dwControlsAccepted = SERVICE_ACCEPT_STOP;
    SetServiceStatus(g_hStatus, &g_Status);
}

static VOID WINAPI ServiceCtrl(DWORD ctrl)
{
    if (ctrl == SERVICE_CONTROL_STOP) {
        ReportStatus(SERVICE_STOP_PENDING, NO_ERROR, 5000);
        SetEvent(g_StopEvent);
    }
}

static VOID WINAPI ServiceMain(DWORD argc, LPSTR* argv)
{
    (void)argc; (void)argv;

    g_Status.dwServiceType             = SERVICE_WIN32_OWN_PROCESS;
    g_Status.dwServiceSpecificExitCode = 0;

    g_hStatus = RegisterServiceCtrlHandlerA("wdaclear", ServiceCtrl);
    if (!g_hStatus) return;

    g_StopEvent = CreateEventA(NULL, TRUE, FALSE, NULL);
    if (!g_StopEvent) { ReportStatus(SERVICE_STOPPED, GetLastError(), 0); return; }

    ReportStatus(SERVICE_START_PENDING, NO_ERROR, 3000);

    // Open the capture driver
    HANDLE hDev = INVALID_HANDLE_VALUE;
    for (int retry = 0; retry < 30 && hDev == INVALID_HANDLE_VALUE; retry++) {
        hDev = CreateFileA("\\\\.\\CaptureDriver",
                           GENERIC_READ | GENERIC_WRITE, 0, NULL,
                           OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
        if (hDev == INVALID_HANDLE_VALUE) Sleep(1000);
    }
    if (hDev == INVALID_HANDLE_VALUE) {
        ReportStatus(SERVICE_STOPPED, GetLastError(), 0);
        return;
    }

    ReportStatus(SERVICE_RUNNING, NO_ERROR, 0);

    // Main loop: clear WDA every 100ms
    while (WaitForSingleObject(g_StopEvent, 100) == WAIT_TIMEOUT) {
        ULONG count = 0;
        DWORD bytes = 0;
        DeviceIoControl(hDev, IOCTL_CAPTURE_GET_FRAME,
                        NULL, 0, &count, sizeof(count), &bytes, NULL);
    }

    CloseHandle(hDev);
    CloseHandle(g_StopEvent);
    ReportStatus(SERVICE_STOPPED, NO_ERROR, 0);
}

int main(void)
{
    SERVICE_TABLE_ENTRYA table[] = {
        { "wdaclear", ServiceMain },
        { NULL, NULL }
    };
    if (!StartServiceCtrlDispatcherA(table)) {
        // Not running as a service — run as a console loop for testing
        HANDLE hDev = CreateFileA("\\\\.\\CaptureDriver",
                                  GENERIC_READ | GENERIC_WRITE, 0, NULL,
                                  OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
        if (hDev == INVALID_HANDLE_VALUE) {
            printf("Cannot open CaptureDriver: %lu\n", GetLastError()); return 1;
        }
        printf("Running in console mode (Ctrl+C to stop)...\n");
        for (;;) {
            ULONG count = 0; DWORD bytes = 0;
            DeviceIoControl(hDev, IOCTL_CAPTURE_GET_FRAME,
                            NULL, 0, &count, sizeof(count), &bytes, NULL);
            if (count > 0) printf("Windows enumerated: %lu\n", count);
            Sleep(100);
        }
    }
    return 0;
}
