/*
 * capturedrv.c - Kernel WDA bypass driver
 *
 * On Windows 11 24H2, GreBitBlt and friends are not exported from any win32k module.
 * Instead this driver clears WDA_EXCLUDEFROMCAPTURE on all session windows by calling
 * NtUserSetWindowDisplayAffinity(hwnd, WDA_NONE) directly from win32kfull.sys while
 * attached to an interactive session process via KeStackAttachProcess.
 *
 * User mode calls IOCTL_CAPTURE_CLEAR_WDA; driver returns count of windows processed.
 * After that, any capture API (GDI BitBlt, WGC) sees previously-protected windows.
 */

#include <wdm.h>
#include <ntimage.h>
#include "capturedrv.h"

// ── Manual declarations ────────────────────────────────────────────────────────

NTSYSAPI NTSTATUS NTAPI ZwQuerySystemInformation(
    ULONG  SystemInformationClass,
    PVOID  SystemInformation,
    ULONG  SystemInformationLength,
    PULONG ReturnLength);

// ── ZwQuerySystemInformation helpers ──────────────────────────────────────────

#define CAPT_SystemModuleInfo   11

typedef struct {
    HANDLE  Section; PVOID MappedBase; PVOID ImageBase; ULONG ImageSize;
    ULONG   Flags; USHORT LoadOrderIndex; USHORT InitOrderIndex;
    USHORT  LoadCount; USHORT OffsetToFileName; UCHAR FullPathName[256];
} CAPT_MODULE_INFO;

typedef struct {
    ULONG NumberOfModules; CAPT_MODULE_INFO Modules[1];
} CAPT_MODULE_LIST, *PCAPT_MODULE_LIST;

// ── Inline string helpers ──────────────────────────────────────────────────────

static BOOLEAN CaptStrEqA(const char* a, const char* b)
{
    while (*a && *b) { if (*a != *b) return FALSE; a++; b++; }
    return (*a == 0 && *b == 0);
}

static BOOLEAN CaptStrEqIA(const char* a, const char* b)
{
    while (*a && *b) {
        char ca = (*a >= 'A' && *a <= 'Z') ? (char)(*a+32) : *a;
        char cb = (*b >= 'A' && *b <= 'Z') ? (char)(*b+32) : *b;
        if (ca != cb) return FALSE; a++; b++;
    }
    return (*a == 0 && *b == 0);
}

// ── Globals ────────────────────────────────────────────────────────────────────

static PDEVICE_OBJECT g_DeviceObject = NULL;
static ULONG          g_FrameWidth   = 1920;
static ULONG          g_FrameHeight  = 1080;
static ULONG          g_FrameStride  = 0;
static ULONG          g_FrameSize    = 0;
static KEVENT         g_FrameReady;
static KSPIN_LOCK     g_FrameLock;

#define POOL_TAG 'DtrC'
#define WDA_NONE 0

// ── Forward declarations ───────────────────────────────────────────────────────

DRIVER_UNLOAD   CaptureDriverUnload;
DRIVER_DISPATCH CaptureDispatchCreate;
DRIVER_DISPATCH CaptureDispatchClose;
DRIVER_DISPATCH CaptureDispatchDeviceControl;

// ── NtUser function types (from win32kfull.sys) ────────────────────────────────
// Use PVOID for HWND/HDESK to avoid conflicts with wdm.h — kernel GDI handles
// are opaque pointers in kernel mode context.

// NtUserSetWindowDisplayAffinity(hwnd, dwAffinity) -> ULONG (BOOL)
typedef ULONG (NTAPI *PFN_NtUserSetWDA)(PVOID hwnd, ULONG dwAffinity);

// NtUserBuildHwndList(hDesktop, hwndNext, fEnumChildren, fEnumThread,
//                     idThread, cHwnd, phwndFirst, pcHwndNeeded) -> NTSTATUS
typedef NTSTATUS (NTAPI *PFN_NtUserBuildHwndList)(
    PVOID    hDesktop,
    PVOID    hwndNext,
    BOOLEAN  fEnumChildren,
    BOOLEAN  fEnumThread,
    ULONG    idThread,
    ULONG    cHwnd,
    PVOID   *phwndFirst,
    PULONG   pcHwndNeeded);

// NtUserGetWindowDisplayAffinity(hwnd, pdwAffinity) -> ULONG (BOOL)
typedef ULONG (NTAPI *PFN_NtUserGetWDA)(PVOID hwnd, PULONG pdwAffinity);

static PFN_NtUserSetWDA         pfnNtUserSetWDA      = NULL;
static PFN_NtUserBuildHwndList  pfnNtUserBuildHwnd   = NULL;
static PFN_NtUserGetWDA         pfnNtUserGetWDA       = NULL;

static BOOLEAN g_NtUserResolved  = FALSE;

// ── PE export resolver (skips forwarded exports) ──────────────────────────────

static PVOID ResolveExport(PVOID base, const char* funcName)
{
    if (!base || !funcName) return NULL;
    __try {
        PIMAGE_DOS_HEADER dos = (PIMAGE_DOS_HEADER)base;
        if (dos->e_magic != IMAGE_DOS_SIGNATURE) return NULL;
        PIMAGE_NT_HEADERS64 nt = (PIMAGE_NT_HEADERS64)((PUCHAR)base + dos->e_lfanew);
        if (nt->Signature != IMAGE_NT_SIGNATURE) return NULL;
        ULONG edRva  = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT].VirtualAddress;
        ULONG edSize = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT].Size;
        if (!edRva) return NULL;
        PIMAGE_EXPORT_DIRECTORY ed = (PIMAGE_EXPORT_DIRECTORY)((PUCHAR)base + edRva);
        PULONG  nameRvas = (PULONG) ((PUCHAR)base + ed->AddressOfNames);
        PUSHORT ordinals = (PUSHORT)((PUCHAR)base + ed->AddressOfNameOrdinals);
        PULONG  funcRvas = (PULONG) ((PUCHAR)base + ed->AddressOfFunctions);
        for (ULONG i = 0; i < ed->NumberOfNames; i++) {
            const char* name = (const char*)((PUCHAR)base + nameRvas[i]);
            if (CaptStrEqA(name, funcName)) {
                ULONG rva = funcRvas[ordinals[i]];
                if (rva >= edRva && rva < edRva + edSize) return NULL; // forwarded
                return (PVOID)((PUCHAR)base + rva);
            }
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {}
    return NULL;
}

// ── Find win32kfull.sys base (called in session context) ──────────────────────

static PVOID FindWin32kFullBase(void)
{
    ULONG sz = 0;
    ZwQuerySystemInformation(CAPT_SystemModuleInfo, NULL, 0, &sz);
    if (!sz) return NULL;
    sz += 4096;
#pragma warning(suppress:4996)
    PCAPT_MODULE_LIST mods = (PCAPT_MODULE_LIST)ExAllocatePoolWithTag(NonPagedPoolNx, sz, POOL_TAG);
    if (!mods) return NULL;
    NTSTATUS st = ZwQuerySystemInformation(CAPT_SystemModuleInfo, mods, sz, &sz);
    PVOID base = NULL;
    if (NT_SUCCESS(st)) {
        for (ULONG i = 0; i < mods->NumberOfModules; i++) {
            const char* n = (const char*)mods->Modules[i].FullPathName
                            + mods->Modules[i].OffsetToFileName;
            if (CaptStrEqIA(n, "win32kfull.sys")) {
                base = mods->Modules[i].ImageBase;
                DbgPrint("capturedrv: win32kfull.sys @ %p\n", base);
                break;
            }
        }
    }
    ExFreePoolWithTag(mods, POOL_TAG);
    return base;
}

// ── Resolve NtUser functions (must run inside KeStackAttachProcess) ────────────

static BOOLEAN EnsureNtUserResolved(void)
{
    PVOID base = FindWin32kFullBase();
    if (!base) { DbgPrint("capturedrv: win32kfull.sys not found\n"); return FALSE; }

    pfnNtUserSetWDA    = (PFN_NtUserSetWDA)       ResolveExport(base, "NtUserSetWindowDisplayAffinity");
    pfnNtUserBuildHwnd = (PFN_NtUserBuildHwndList) ResolveExport(base, "NtUserBuildHwndList");
    pfnNtUserGetWDA    = (PFN_NtUserGetWDA)        ResolveExport(base, "NtUserGetWindowDisplayAffinity");

    DbgPrint("capturedrv: NtUserSetWDA=%p BuildHwnd=%p GetWDA=%p\n",
             pfnNtUserSetWDA, pfnNtUserBuildHwnd, pfnNtUserGetWDA);

    return (pfnNtUserSetWDA != NULL && pfnNtUserBuildHwnd != NULL);
}

// ── Clear WDA on all session windows ─────────────────────────────────────────
// Called directly in the IOCTL caller's thread context.
// The caller MUST be a GUI process in the interactive session (session 1)
// so that win32k has a valid THREADINFO and desktop association.
// wdaclear.exe creates a hidden window before calling the IOCTL to ensure this.

static NTSTATUS ClearAllWDA(PULONG pCleared)
{
    // Resolve NtUser exports once — just PE walking, works from any context
    if (!g_NtUserResolved) {
        g_NtUserResolved = EnsureNtUserResolved();
    }
    if (!g_NtUserResolved) {
        DbgPrint("capturedrv: NtUser not resolved\n");
        return STATUS_NOT_FOUND;
    }

    NTSTATUS st = STATUS_SUCCESS;
    PVOID* hwnds = NULL;

    __try {
        // Size query: how many HWNDs are on the current desktop?
        ULONG needed = 0;
        pfnNtUserBuildHwnd(NULL, NULL, FALSE, FALSE, 0, 0, NULL, &needed);
        if (needed == 0) needed = 512;

        ULONG bufCount = needed + 128;
#pragma warning(suppress:4996)
        hwnds = (PVOID*)ExAllocatePoolWithTag(NonPagedPoolNx,
                                               bufCount * sizeof(PVOID), POOL_TAG);
        if (!hwnds) { st = STATUS_INSUFFICIENT_RESOURCES; __leave; }

        ULONG actual = 0;
        st = pfnNtUserBuildHwnd(NULL, NULL, FALSE, FALSE, 0, bufCount, hwnds, &actual);

        ULONG cleared = 0;
        if (NT_SUCCESS(st) && actual > 0) {
            for (ULONG i = 0; i < actual; i++) {
                if (!hwnds[i]) continue;
                __try {
                    pfnNtUserSetWDA(hwnds[i], WDA_NONE);
                    cleared++;
                } __except (EXCEPTION_EXECUTE_HANDLER) {}
            }
        }

        ExFreePoolWithTag(hwnds, POOL_TAG);
        hwnds = NULL;
        if (pCleared) *pCleared = actual;
        DbgPrint("capturedrv: enumerated %lu windows, cleared %lu\n", actual, cleared);
        st = STATUS_SUCCESS;

    } __except (EXCEPTION_EXECUTE_HANDLER) {
        DbgPrint("capturedrv: exception in ClearAllWDA: %08X\n", GetExceptionCode());
        if (hwnds) { ExFreePoolWithTag(hwnds, POOL_TAG); }
        st = STATUS_ACCESS_VIOLATION;
    }

    return st;
}

// ── IRP Dispatch ──────────────────────────────────────────────────────────────

NTSTATUS CaptureDispatchCreate(PDEVICE_OBJECT DeviceObject, PIRP Irp)
{
    UNREFERENCED_PARAMETER(DeviceObject);
    Irp->IoStatus.Status = STATUS_SUCCESS; Irp->IoStatus.Information = 0;
    IoCompleteRequest(Irp, IO_NO_INCREMENT); return STATUS_SUCCESS;
}

NTSTATUS CaptureDispatchClose(PDEVICE_OBJECT DeviceObject, PIRP Irp)
{
    UNREFERENCED_PARAMETER(DeviceObject);
    Irp->IoStatus.Status = STATUS_SUCCESS; Irp->IoStatus.Information = 0;
    IoCompleteRequest(Irp, IO_NO_INCREMENT); return STATUS_SUCCESS;
}

NTSTATUS CaptureDispatchDeviceControl(PDEVICE_OBJECT DeviceObject, PIRP Irp)
{
    UNREFERENCED_PARAMETER(DeviceObject);
    PIO_STACK_LOCATION stack = IoGetCurrentIrpStackLocation(Irp);
    ULONG     code   = stack->Parameters.DeviceIoControl.IoControlCode;
    NTSTATUS  status = STATUS_SUCCESS;
    ULONG_PTR info   = 0;

    switch (code)
    {
    case IOCTL_CAPTURE_GET_INFO:
    {
        if (stack->Parameters.DeviceIoControl.OutputBufferLength < sizeof(CAPTURE_INFO)) {
            status = STATUS_BUFFER_TOO_SMALL; break;
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

    case IOCTL_CAPTURE_GET_FRAME: // repurposed: clear WDA, return window count
    {
        ULONG cleared = 0;
        status = ClearAllWDA(&cleared);
        if (NT_SUCCESS(status)) {
            // Return cleared count in output buffer if provided
            if (stack->Parameters.DeviceIoControl.OutputBufferLength >= sizeof(ULONG)
                && Irp->AssociatedIrp.SystemBuffer) {
                *(PULONG)Irp->AssociatedIrp.SystemBuffer = cleared;
                info = sizeof(ULONG);
            }
            KeSetEvent(&g_FrameReady, IO_NO_INCREMENT, FALSE);
        }
        break;
    }

    case IOCTL_CAPTURE_SET_RESOLUTION:
    {
        if (stack->Parameters.DeviceIoControl.InputBufferLength < sizeof(CAPTURE_RESOLUTION)) {
            status = STATUS_BUFFER_TOO_SMALL; break;
        }
        PCAPTURE_RESOLUTION req = (PCAPTURE_RESOLUTION)Irp->AssociatedIrp.SystemBuffer;
        if (req->Width == 0 || req->Height == 0 ||
            req->Width > CAPTURE_MAX_WIDTH || req->Height > CAPTURE_MAX_HEIGHT) {
            status = STATUS_INVALID_PARAMETER; break;
        }
        KIRQL irql;
        KeAcquireSpinLock(&g_FrameLock, &irql);
        g_FrameWidth  = req->Width;
        g_FrameHeight = req->Height;
        g_FrameStride = g_FrameWidth  * CAPTURE_BPP;
        g_FrameSize   = g_FrameStride * g_FrameHeight;
        KeReleaseSpinLock(&g_FrameLock, irql);
        break;
    }

    default:
        status = STATUS_INVALID_DEVICE_REQUEST; break;
    }

    Irp->IoStatus.Status      = status;
    Irp->IoStatus.Information = info;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return status;
}

// ── Unload ────────────────────────────────────────────────────────────────────

VOID CaptureDriverUnload(PDRIVER_OBJECT DriverObject)
{
    UNREFERENCED_PARAMETER(DriverObject);

    UNICODE_STRING sym = RTL_CONSTANT_STRING(CAPTUREDRV_SYMLINK);
    IoDeleteSymbolicLink(&sym);
    if (g_DeviceObject) { IoDeleteDevice(g_DeviceObject); g_DeviceObject = NULL; }
    DbgPrint("capturedrv: Unloaded\n");
}

// ── DriverEntry ───────────────────────────────────────────────────────────────

NTSTATUS DriverEntry(PDRIVER_OBJECT DriverObject, PUNICODE_STRING RegistryPath)
{
    UNREFERENCED_PARAMETER(RegistryPath);
    DbgPrint("capturedrv: DriverEntry (WDA bypass build)\n");

    KeInitializeEvent(&g_FrameReady, NotificationEvent, FALSE);
    KeInitializeSpinLock(&g_FrameLock);

    g_FrameWidth  = 1920;
    g_FrameHeight = 1080;
    g_FrameStride = g_FrameWidth  * CAPTURE_BPP;
    g_FrameSize   = g_FrameStride * g_FrameHeight;

    UNICODE_STRING devName = RTL_CONSTANT_STRING(CAPTUREDRV_DEVICE_NAME);
    NTSTATUS st = IoCreateDevice(DriverObject, 0, &devName,
                                 FILE_DEVICE_UNKNOWN, FILE_DEVICE_SECURE_OPEN,
                                 FALSE, &g_DeviceObject);
    if (!NT_SUCCESS(st)) { DbgPrint("capturedrv: IoCreateDevice failed: %08X\n", st); return st; }

    UNICODE_STRING symLink = RTL_CONSTANT_STRING(CAPTUREDRV_SYMLINK);
    st = IoCreateSymbolicLink(&symLink, &devName);
    if (!NT_SUCCESS(st)) {
        DbgPrint("capturedrv: IoCreateSymbolicLink failed: %08X\n", st);
        IoDeleteDevice(g_DeviceObject); return st;
    }

    DriverObject->DriverUnload                          = CaptureDriverUnload;
    DriverObject->MajorFunction[IRP_MJ_CREATE]         = CaptureDispatchCreate;
    DriverObject->MajorFunction[IRP_MJ_CLOSE]          = CaptureDispatchClose;
    DriverObject->MajorFunction[IRP_MJ_DEVICE_CONTROL] = CaptureDispatchDeviceControl;

    g_DeviceObject->Flags |= DO_BUFFERED_IO;
    g_DeviceObject->Flags &= ~DO_DEVICE_INITIALIZING;

    DbgPrint("capturedrv: Loaded OK — call IOCTL_CAPTURE_GET_FRAME to clear WDA\n");
    return STATUS_SUCCESS;
}
