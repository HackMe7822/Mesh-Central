#pragma once

// Device names
#define CAPTUREDRV_DEVICE_NAME  L"\\Device\\CaptureDriver"
#define CAPTUREDRV_SYMLINK      L"\\DosDevices\\CaptureDriver"
#define CAPTUREDRV_WIN32_NAME   "\\\\.\\CaptureDriver"

// IOCTL codes
#define IOCTL_CAPTURE_GET_INFO \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x800, METHOD_BUFFERED, FILE_ANY_ACCESS)

#define IOCTL_CAPTURE_GET_FRAME \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x801, METHOD_BUFFERED, FILE_ANY_ACCESS)

#define IOCTL_CAPTURE_SET_RESOLUTION \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x802, METHOD_BUFFERED, FILE_ANY_ACCESS)

// IOCTL 0x803: clear WDA on a single HWND passed from user mode
// Input: CLEAR_WDA_HWND struct.  Output: none.
#define IOCTL_CAPTURE_CLEAR_WDA_HWND \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x803, METHOD_BUFFERED, FILE_ANY_ACCESS)

// Shared between kernel and user mode
#pragma pack(push, 1)

typedef struct _CAPTURE_INFO {
    ULONG Width;
    ULONG Height;
    ULONG Stride;       // bytes per row (Width * 4 for BGRA)
    ULONG FrameSize;    // total bytes (Stride * Height)
    ULONG Format;       // 0 = BGRA32
} CAPTURE_INFO, *PCAPTURE_INFO;

typedef struct _CAPTURE_RESOLUTION {
    ULONG Width;
    ULONG Height;
} CAPTURE_RESOLUTION, *PCAPTURE_RESOLUTION;

// Input for IOCTL_CAPTURE_CLEAR_WDA_HWND
// hwnd64 holds the HWND value as a 64-bit integer so the struct is
// the same size from both 32-bit and 64-bit user-mode callers.
typedef struct _CLEAR_WDA_HWND {
    ULONG64 hwnd64;
} CLEAR_WDA_HWND, *PCLEAR_WDA_HWND;

#pragma pack(pop)

// Max supported resolution
#define CAPTURE_MAX_WIDTH   3840
#define CAPTURE_MAX_HEIGHT  2160
#define CAPTURE_BPP         4       // BGRA
