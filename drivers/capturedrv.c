/*
 * capturedrv.c - Kernel mode screen capture driver
 *
 * Captures the screen via win32k GRE functions, bypassing SetWindowDisplayAffinity.
 * Exposes frames to user mode via IOCTL.
 *
 * Build: WDK x64, Windows 10/11 target
 * Sign:  bcdedit /set testsigning on  (dev)
 *        EV cert + Microsoft attestation  (production)
 */

#include <ntddk.h>
#include <wdm.h>
#include <ntimage.h>
#include "capturedrv.h"

// Kernel-mode stand-ins for opaque GDI handles (they're just pointers internally)
typedef PVOID HDC;
typedef PVOID HBITMAP;
#ifndef BOOL
typedef int BOOL;
#endif
#define SRCCOPY 0x00CC0020L

// PsLoadedModuleList - undocumented ntoskrnl export: head of loaded kernel module list
extern PLIST_ENTRY PsLoadedModuleList;

// Minimal LDR_DATA_TABLE_ENTRY for walking the kernel module list
typedef struct _CDRV_LDR_ENTRY {
    LIST_ENTRY InLoadOrderLinks;
    LIST_ENTRY InMemoryOrderLinks;
    LIST_ENTRY InInitializationOrderLinks;
    PVOID      DllBase;
    PVOID      EntryPoint;
    ULONG      SizeOfImage;
    UNICODE_STRING FullDllName;
    UNICODE_STRING BaseDllName;
} CDRV_LDR_ENTRY, *PCDRV_LDR_ENTRY;

// ─── Globals ──────────────────────────────────────────────────────────────────

static PDEVICE_OBJECT g_DeviceObject = NULL;
static PVOID          g_FrameBuffer  = NULL;
static ULONG          g_FrameWidth   = 1920;
static ULONG          g_FrameHeight  = 1080;
static ULONG          g_FrameStride  = 0;
static ULONG          g_FrameSize    = 0;
static KEVENT         g_FrameReady;
static KSPIN_LOCK     g_FrameLock;

#define POOL_TAG 'DtrC'

// ─── Forward declarations ─────────────────────────────────────────────────────

DRIVER_UNLOAD   CaptureDriverUnload;
DRIVER_DISPATCH CaptureDispatchCreate;
DRIVER_DISPATCH CaptureDispatchClose;
DRIVER_DISPATCH CaptureDispatchDeviceControl;

// ─── GRE function types (win32k kernel-level GDI) ────────────────────────────

typedef HDC     (NTAPI *PFN_GreCreateCompatibleDC)(HDC hdc);
typedef BOOL    (NTAPI *PFN_GreBitBlt)(HDC hdcDst, int x, int y, int cx, int cy,
                                        HDC hdcSrc, int xSrc, int ySrc, ULONG rop);
typedef BOOL    (NTAPI *PFN_GreDeleteDC)(HDC hdc);
typedef HBITMAP (NTAPI *PFN_GreCreateBitmap)(int cx, int cy, ULONG cPlanes,
                                              ULONG cBitsPerPel, PVOID pvBits);

static PFN_GreCreateCompatibleDC pfnGreCreateCompatibleDC = NULL;
static PFN_GreBitBlt             pfnGreBitBlt             = NULL;
static PFN_GreDeleteDC           pfnGreDeleteDC           = NULL;
static PFN_GreCreateBitmap       pfnGreCreateBitmap       = NULL;

static HDC     g_ScreenDC      = NULL;
static HDC     g_CaptureDC     = NULL;
static HBITMAP g_CaptureBitmap = NULL;

// ─── Resolve a win32k.sys export by name ─────────────────────────────────────

static PVOID ResolveWin32kExport(PCSTR funcName)
{
    UNICODE_STRING win32kName;
    RtlInitUnicodeString(&win32kName, L"win32k.sys");

    PVOID base = NULL;

    if (!PsLoadedModuleList) return NULL;

    PLIST_ENTRY head = PsLoadedModuleList;
    PLIST_ENTRY cur  = head->Flink;

    while (cur && cur != head) {
        PCDRV_LDR_ENTRY entry = CONTAINING_RECORD(cur, CDRV_LDR_ENTRY, InLoadOrderLinks);
        if (RtlEqualUnicodeString(&entry->BaseDllName, &win32kName, TRUE)) {
            base = entry->DllBase;
            break;
        }
        cur = cur->Flink;
    }

    if (!base) {
        DbgPrint("capturedrv: win32k.sys not found in module list\n");
        return NULL;
    }

    // Walk PE export table
    PIMAGE_DOS_HEADER dos = (PIMAGE_DOS_HEADER)base;
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return NULL;

    PIMAGE_NT_HEADERS64 nt = (PIMAGE_NT_HEADERS64)((PUCHAR)base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return NULL;

    ULONG expRva = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT].VirtualAddress;
    if (!expRva) return NULL;

    PIMAGE_EXPORT_DIRECTORY exp = (PIMAGE_EXPORT_DIRECTORY)((PUCHAR)base + expRva);
    PULONG  nameRvas  = (PULONG) ((PUCHAR)base + exp->AddressOfNames);
    PUSHORT ordinals  = (PUSHORT)((PUCHAR)base + exp->AddressOfNameOrdinals);
    PULONG  funcRvas  = (PULONG) ((PUCHAR)base + exp->AddressOfFunctions);

    for (ULONG i = 0; i < exp->NumberOfNames; i++) {
        PCSTR name = (PCSTR)((PUCHAR)base + nameRvas[i]);
        if (strcmp(name, funcName) == 0) {
            return (PVOID)((PUCHAR)base + funcRvas[ordinals[i]]);
        }
    }

    DbgPrint("capturedrv: '%s' not found in win32k.sys\n", funcName);
    return NULL;
}

// ─── Initialize capture DCs ───────────────────────────────────────────────────

static NTSTATUS InitCaptureDC(void)
{
    if (!pfnGreCreateCompatibleDC || !pfnGreBitBlt ||
        !pfnGreDeleteDC || !pfnGreCreateBitmap)
    {
        return STATUS_NOT_FOUND;
    }

    ULONG bitmapBytes = g_FrameStride * g_FrameHeight;

    if (g_FrameBuffer) {
        ExFreePoolWithTag(g_FrameBuffer, POOL_TAG);
        g_FrameBuffer = NULL;
    }

#pragma warning(suppress: 4996)
    g_FrameBuffer = ExAllocatePoolWithTag(NonPagedPoolNx, bitmapBytes, POOL_TAG);
    if (!g_FrameBuffer) return STATUS_INSUFFICIENT_RESOURCES;

    g_CaptureBitmap = pfnGreCreateBitmap(
        (int)g_FrameWidth, (int)g_FrameHeight, (ULONG)1, (ULONG)32, g_FrameBuffer);

    if (!g_CaptureBitmap) {
        DbgPrint("capturedrv: GreCreateBitmap failed\n");
        ExFreePoolWithTag(g_FrameBuffer, POOL_TAG);
        g_FrameBuffer = NULL;
        return STATUS_UNSUCCESSFUL;
    }

    g_ScreenDC  = pfnGreCreateCompatibleDC(NULL);
    g_CaptureDC = pfnGreCreateCompatibleDC(g_ScreenDC);

    if (!g_ScreenDC || !g_CaptureDC) {
        DbgPrint("capturedrv: GreCreateCompatibleDC failed\n");
        return STATUS_UNSUCCESSFUL;
    }

    return STATUS_SUCCESS;
}

// ─── Capture one frame ────────────────────────────────────────────────────────

static NTSTATUS CaptureFrame(void)
{
    if (!g_ScreenDC || !g_CaptureDC || !g_CaptureBitmap || !pfnGreBitBlt)
        return STATUS_DEVICE_NOT_READY;

    KIRQL oldIrql;
    KeAcquireSpinLock(&g_FrameLock, &oldIrql);

    BOOL ok = pfnGreBitBlt(
        g_CaptureDC, 0, 0, (int)g_FrameWidth, (int)g_FrameHeight,
        g_ScreenDC,  0, 0, SRCCOPY);

    KeReleaseSpinLock(&g_FrameLock, oldIrql);

    if (!ok) {
        DbgPrint("capturedrv: GreBitBlt failed\n");
        return STATUS_UNSUCCESSFUL;
    }

    KeSetEvent(&g_FrameReady, IO_NO_INCREMENT, FALSE);
    return STATUS_SUCCESS;
}

// ─── IRP Dispatch ─────────────────────────────────────────────────────────────

NTSTATUS CaptureDispatchCreate(PDEVICE_OBJECT DeviceObject, PIRP Irp)
{
    UNREFERENCED_PARAMETER(DeviceObject);
    Irp->IoStatus.Status      = STATUS_SUCCESS;
    Irp->IoStatus.Information = 0;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return STATUS_SUCCESS;
}

NTSTATUS CaptureDispatchClose(PDEVICE_OBJECT DeviceObject, PIRP Irp)
{
    UNREFERENCED_PARAMETER(DeviceObject);
    Irp->IoStatus.Status      = STATUS_SUCCESS;
    Irp->IoStatus.Information = 0;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return STATUS_SUCCESS;
}

NTSTATUS CaptureDispatchDeviceControl(PDEVICE_OBJECT DeviceObject, PIRP Irp)
{
    UNREFERENCED_PARAMETER(DeviceObject);

    PIO_STACK_LOCATION stack = IoGetCurrentIrpStackLocation(Irp);
    ULONG    code   = stack->Parameters.DeviceIoControl.IoControlCode;
    NTSTATUS status = STATUS_SUCCESS;
    ULONG_PTR info  = 0;

    switch (code)
    {
    case IOCTL_CAPTURE_GET_INFO:
    {
        if (stack->Parameters.DeviceIoControl.OutputBufferLength < sizeof(CAPTURE_INFO)) {
            status = STATUS_BUFFER_TOO_SMALL;
            break;
        }
        PCAPTURE_INFO out = (PCAPTURE_INFO)Irp->AssociatedIrp.SystemBuffer;
        out->Width     = g_FrameWidth;
        out->Height    = g_FrameHeight;
        out->Stride    = g_FrameStride;
        out->FrameSize = g_FrameSize;
        out->Format    = 0;
        info = sizeof(CAPTURE_INFO);
        break;
    }

    case IOCTL_CAPTURE_SET_RESOLUTION:
    {
        if (stack->Parameters.DeviceIoControl.InputBufferLength < sizeof(CAPTURE_RESOLUTION)) {
            status = STATUS_BUFFER_TOO_SMALL;
            break;
        }
        PCAPTURE_RESOLUTION req = (PCAPTURE_RESOLUTION)Irp->AssociatedIrp.SystemBuffer;
        if (req->Width == 0 || req->Height == 0 ||
            req->Width > CAPTURE_MAX_WIDTH || req->Height > CAPTURE_MAX_HEIGHT) {
            status = STATUS_INVALID_PARAMETER;
            break;
        }
        g_FrameWidth  = req->Width;
        g_FrameHeight = req->Height;
        g_FrameStride = g_FrameWidth * CAPTURE_BPP;
        g_FrameSize   = g_FrameStride * g_FrameHeight;
        status = InitCaptureDC();
        break;
    }

    case IOCTL_CAPTURE_GET_FRAME:
    {
        status = CaptureFrame();
        if (!NT_SUCCESS(status)) break;

        if (!Irp->MdlAddress) {
            status = STATUS_INVALID_PARAMETER;
            break;
        }
        PVOID userBuf = MmGetSystemAddressForMdlSafe(Irp->MdlAddress, NormalPagePriority);
        if (!userBuf) {
            status = STATUS_INSUFFICIENT_RESOURCES;
            break;
        }
        ULONG outLen = stack->Parameters.DeviceIoControl.OutputBufferLength;
        if (outLen < g_FrameSize) {
            status = STATUS_BUFFER_TOO_SMALL;
            break;
        }

        KIRQL oldIrql;
        KeAcquireSpinLock(&g_FrameLock, &oldIrql);
        if (g_FrameBuffer) {
            RtlCopyMemory(userBuf, g_FrameBuffer, g_FrameSize);
            info = g_FrameSize;
        } else {
            status = STATUS_DEVICE_NOT_READY;
        }
        KeReleaseSpinLock(&g_FrameLock, oldIrql);
        break;
    }

    default:
        status = STATUS_INVALID_DEVICE_REQUEST;
        break;
    }

    Irp->IoStatus.Status      = status;
    Irp->IoStatus.Information = info;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return status;
}

// ─── Unload ───────────────────────────────────────────────────────────────────

VOID CaptureDriverUnload(PDRIVER_OBJECT DriverObject)
{
    UNREFERENCED_PARAMETER(DriverObject);

    UNICODE_STRING symLink = RTL_CONSTANT_STRING(CAPTUREDRV_SYMLINK);
    IoDeleteSymbolicLink(&symLink);

    if (g_DeviceObject) {
        IoDeleteDevice(g_DeviceObject);
        g_DeviceObject = NULL;
    }

    if (pfnGreDeleteDC) {
        if (g_CaptureDC) { pfnGreDeleteDC(g_CaptureDC); g_CaptureDC = NULL; }
        if (g_ScreenDC)  { pfnGreDeleteDC(g_ScreenDC);  g_ScreenDC  = NULL; }
    }

    if (g_FrameBuffer) {
        ExFreePoolWithTag(g_FrameBuffer, POOL_TAG);
        g_FrameBuffer = NULL;
    }

    DbgPrint("capturedrv: Unloaded\n");
}

// ─── DriverEntry ──────────────────────────────────────────────────────────────

NTSTATUS DriverEntry(PDRIVER_OBJECT DriverObject, PUNICODE_STRING RegistryPath)
{
    UNREFERENCED_PARAMETER(RegistryPath);

    NTSTATUS status;
    DbgPrint("capturedrv: Loading...\n");

    KeInitializeEvent(&g_FrameReady, NotificationEvent, FALSE);
    KeInitializeSpinLock(&g_FrameLock);

    g_FrameWidth  = 1920;
    g_FrameHeight = 1080;
    g_FrameStride = g_FrameWidth  * CAPTURE_BPP;
    g_FrameSize   = g_FrameStride * g_FrameHeight;

    UNICODE_STRING deviceName = RTL_CONSTANT_STRING(CAPTUREDRV_DEVICE_NAME);
    status = IoCreateDevice(
        DriverObject, 0, &deviceName,
        FILE_DEVICE_UNKNOWN, FILE_DEVICE_SECURE_OPEN,
        FALSE, &g_DeviceObject);

    if (!NT_SUCCESS(status)) {
        DbgPrint("capturedrv: IoCreateDevice failed: 0x%08X\n", status);
        return status;
    }

    UNICODE_STRING symLink = RTL_CONSTANT_STRING(CAPTUREDRV_SYMLINK);
    status = IoCreateSymbolicLink(&symLink, &deviceName);
    if (!NT_SUCCESS(status)) {
        DbgPrint("capturedrv: IoCreateSymbolicLink failed: 0x%08X\n", status);
        IoDeleteDevice(g_DeviceObject);
        return status;
    }

    DriverObject->DriverUnload                          = CaptureDriverUnload;
    DriverObject->MajorFunction[IRP_MJ_CREATE]         = CaptureDispatchCreate;
    DriverObject->MajorFunction[IRP_MJ_CLOSE]          = CaptureDispatchClose;
    DriverObject->MajorFunction[IRP_MJ_DEVICE_CONTROL] = CaptureDispatchDeviceControl;

    g_DeviceObject->Flags |= DO_BUFFERED_IO;
    g_DeviceObject->Flags &= ~DO_DEVICE_INITIALIZING;

    // Resolve win32k GRE functions (kernel-level screen capture)
    pfnGreCreateCompatibleDC = (PFN_GreCreateCompatibleDC)ResolveWin32kExport("GreCreateCompatibleDC");
    pfnGreBitBlt             = (PFN_GreBitBlt)            ResolveWin32kExport("GreBitBlt");
    pfnGreDeleteDC           = (PFN_GreDeleteDC)          ResolveWin32kExport("GreDeleteDC");
    pfnGreCreateBitmap       = (PFN_GreCreateBitmap)      ResolveWin32kExport("GreCreateBitmap");

    if (!pfnGreCreateCompatibleDC || !pfnGreBitBlt || !pfnGreDeleteDC || !pfnGreCreateBitmap) {
        DbgPrint("capturedrv: WARNING - GRE functions not resolved. Check export names for your build.\n");
    } else {
        status = InitCaptureDC();
        if (!NT_SUCCESS(status)) {
            DbgPrint("capturedrv: InitCaptureDC failed: 0x%08X\n", status);
        } else {
            DbgPrint("capturedrv: Capture DC ready (%ux%u)\n", g_FrameWidth, g_FrameHeight);
        }
    }

    DbgPrint("capturedrv: Loaded. Device: %s\n", CAPTUREDRV_WIN32_NAME);
    return STATUS_SUCCESS;
}
