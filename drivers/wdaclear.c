/*
 * wdaclear.c - Clears WDA_EXCLUDEFROMCAPTURE on all windows, all desktops.
 *
 * Root-cause fix for exam browsers that run on a SEPARATE DESKTOP:
 *   - Old approach: capturedrv.sys enumerated windows from kernel → only saw
 *     the calling thread's desktop → 0 windows found on the exam desktop.
 *   - New approach: wdaclear.exe enumerates ALL desktops in user mode (admin
 *     can open any desktop within the same session), finds windows with WDA,
 *     then passes each HWND to the driver which calls NtUserSetWindowDisplayAffinity
 *     from kernel mode — bypassing the cross-process ownership restriction.
 *
 * Requires: capturedrv.sys loaded.
 * Auto-start: HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run -> WdaClear
 */

#include <windows.h>
#include <stdio.h>

/* ── IOCTL definitions (must match capturedrv.h) ──────────────────────────── */
#define FILE_DEVICE_UNKNOWN 0x00000022
#define METHOD_BUFFERED     0
#define FILE_ANY_ACCESS     0
#ifndef CTL_CODE
#define CTL_CODE(d,f,m,a) (((d)<<16)|((a)<<14)|((f)<<2)|(m))
#endif

/* Old IOCTL: kernel enumerates windows — left in for compat */
#define IOCTL_CAPTURE_GET_FRAME \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x801, METHOD_BUFFERED, FILE_ANY_ACCESS)

/* New IOCTL: user mode passes a single HWND, driver clears WDA on it */
#define IOCTL_CAPTURE_CLEAR_WDA_HWND \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x803, METHOD_BUFFERED, FILE_ANY_ACCESS)

typedef struct { ULONG64 hwnd64; } CLEAR_WDA_HWND;

/* ── Globals ──────────────────────────────────────────────────────────────── */
static HANDLE g_hDev   = INVALID_HANDLE_VALUE;
static LONG   g_total  = 0;   // total HWNDs cleared since start

/* ── Send one HWND to the driver to clear WDA ─────────────────────────────── */
static void ClearOneHwnd(HWND hwnd)
{
    CLEAR_WDA_HWND req;
    req.hwnd64 = (ULONG64)(ULONG_PTR)hwnd;
    DWORD bytes = 0;
    DeviceIoControl(g_hDev, IOCTL_CAPTURE_CLEAR_WDA_HWND,
                    &req, sizeof(req), NULL, 0, &bytes, NULL);
}

/* ── EnumWindows callback: check WDA, clear via driver ───────────────────── */
static BOOL CALLBACK EnumWndCb(HWND hwnd, LPARAM lp)
{
    DWORD aff = 0;
    if (GetWindowDisplayAffinity(hwnd, &aff) && aff != WDA_NONE) {
        ClearOneHwnd(hwnd);
        InterlockedIncrement(&g_total);
    }
    return TRUE;
}

/* ── Enumerate desktops callback ──────────────────────────────────────────── */
static BOOL CALLBACK EnumDeskCb(LPTSTR name, LPARAM lp)
{
    HDESK hd = OpenDesktopA(name,
                            0,           // dwFlags
                            FALSE,       // fInherit
                            DESKTOP_ENUMERATE | DESKTOP_READOBJECTS |
                            DESKTOP_WRITEOBJECTS | GENERIC_READ);
    if (!hd) return TRUE; // skip inaccessible desktops, keep going

    EnumDesktopWindows(hd, EnumWndCb, 0);
    CloseDesktop(hd);
    return TRUE;
}

/* ── Window procedure ─────────────────────────────────────────────────────── */
#define TIMER_ID  1
#define TIMER_MS  100   /* 10 Hz clear rate — exam browsers typically set WDA
                           only once at startup, so 100 ms is plenty */

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    if (msg == WM_TIMER && wp == TIMER_ID) {
        /* Enumerate ALL desktops in WinSta0 (NULL = current window station).
           Exam browsers always run in WinSta0 but may switch to their own
           desktop (e.g. "ExamDesktop") — EnumDesktops opens each one. */
        EnumDesktopsA(NULL, EnumDeskCb, 0);

        /* Also sweep the current desktop for anything EnumDesktops missed */
        EnumWindows(EnumWndCb, 0);
        return 0;
    }
    if (msg == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcA(hwnd, msg, wp, lp);
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR lpCmd, int nShow)
{
    (void)hPrev; (void)lpCmd; (void)nShow;

    /* Hidden message window — also initialises win32k THREADINFO for this
       thread so the driver (when called via IOCTL) runs in a proper GUI
       thread context. */
    WNDCLASSA wc = {0};
    wc.lpfnWndProc   = WndProc;
    wc.hInstance     = hInst;
    wc.lpszClassName = "WdaClearHidden";
    RegisterClassA(&wc);

    HWND hwnd = CreateWindowExA(0, "WdaClearHidden", "WdaClear",
                                0, 0, 0, 0, 0,
                                HWND_MESSAGE, NULL, hInst, NULL);
    if (!hwnd) return 1;

    /* Wait up to 30 s for capturedrv.sys to appear */
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
