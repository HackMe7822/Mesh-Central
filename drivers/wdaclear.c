/*
 * wdaclear.c - GUI helper that clears WDA_EXCLUDEFROMCAPTURE every 100ms.
 *
 * Must run as a regular process in the interactive session (NOT as a service).
 * Creating a hidden window initializes win32k THREADINFO so the kernel driver's
 * NtUserBuildHwndList call sees the correct desktop and enumerates all windows.
 *
 * Auto-start: add to HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run
 *   reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v WdaClear /d "C:\wdaclear.exe" /f
 */

#include <windows.h>

#define FILE_DEVICE_UNKNOWN 0x00000022
#define METHOD_BUFFERED     0
#define FILE_ANY_ACCESS     0
#ifndef CTL_CODE
#define CTL_CODE(d,f,m,a) (((d)<<16)|((a)<<14)|((f)<<2)|(m))
#endif
#define IOCTL_CAPTURE_GET_FRAME \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x801, METHOD_BUFFERED, FILE_ANY_ACCESS)

#define TIMER_ID 1
#define TIMER_MS 100

static HANDLE g_hDev = INVALID_HANDLE_VALUE;

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    if (msg == WM_TIMER && wp == TIMER_ID) {
        if (g_hDev != INVALID_HANDLE_VALUE) {
            ULONG count = 0;
            DWORD bytes = 0;
            DeviceIoControl(g_hDev, IOCTL_CAPTURE_GET_FRAME,
                            NULL, 0, &count, sizeof(count), &bytes, NULL);
        }
        return 0;
    }
    if (msg == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcA(hwnd, msg, wp, lp);
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR lpCmd, int nShow)
{
    (void)hPrev; (void)lpCmd; (void)nShow;

    // Hidden message-only window — this is the key step that initialises
    // win32k THREADINFO for this thread so the driver's NtUserBuildHwndList
    // call (which runs in this thread's kernel context) sees the interactive
    // desktop and can enumerate all windows.
    WNDCLASSA wc = {0};
    wc.lpfnWndProc   = WndProc;
    wc.hInstance     = hInst;
    wc.lpszClassName = "WdaClearHidden";
    RegisterClassA(&wc);

    HWND hwnd = CreateWindowExA(0, "WdaClearHidden", "WdaClear",
                                0, 0, 0, 0, 0,
                                HWND_MESSAGE, NULL, hInst, NULL);
    if (!hwnd) return 1;

    // Wait up to 30 s for the driver to load
    for (int i = 0; i < 30 && g_hDev == INVALID_HANDLE_VALUE; i++) {
        g_hDev = CreateFileA("\\\\.\\CaptureDriver",
                             GENERIC_READ | GENERIC_WRITE, 0, NULL,
                             OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
        if (g_hDev == INVALID_HANDLE_VALUE) Sleep(1000);
    }
    if (g_hDev == INVALID_HANDLE_VALUE) return 2;

    SetTimer(hwnd, TIMER_ID, TIMER_MS, NULL);

    MSG msg;
    while (GetMessageA(&msg, NULL, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessageA(&msg);
    }

    KillTimer(hwnd, TIMER_ID);
    CloseHandle(g_hDev);
    return 0;
}
