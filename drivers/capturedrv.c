/*
 * capturedrv.c - Kernel mode screen capture driver
 *
 * Captures the screen via win32k GRE functions, bypassing WDA_EXCLUDEFROMCAPTURE.
 * Exposes frames to user mode via IOCTL.
 *
 * Key design choices:
 *  - No aux_klib (CRT initializers before DriverEntry = BSOD)
 *  - No CRT functions — inline replacements only
 *  - ZwQuerySystemInformation used directly (exported from ntoskrnl.lib)
 *  - GRE functions resolved from win32k.sys, win32kfull.sys, win32kbase.sys
 *  - Forwarded PE exports are skipped; real impl found in the exporting module
 *  - All GRE calls (including resolution) inside KeStackAttachProcess on Session 1
 *  - g_GREResolved only set TRUE after ALL function ptrs are non-NULL
 */

#include <wdm.h>
#include <ntimage.h>
#include "capturedrv.h"

// ── Manual declarations: not in wdm.h ─────────────────────────────────────────

NTSYSAPI NTSTATUS NTAPI ZwQuerySystemInformation(
    ULONG  SystemInformationClass,
    PVOID  SystemInformation,
    ULONG  SystemInformationLength,
    PULONG ReturnLength);

typedef struct _KAPC_STATE {
    LIST_ENTRY ApcListHead[2];
    PKPROCESS  Process;
    BOOLEAN    KernelApcInProgress;
    BOOLEAN    KernelApcPending;
    BOOLEAN    UserApcPending;
} KAPC_STATE, *PKAPC_STATE;

NTKERNELAPI VOID KeStackAttachProcess(PEPROCESS Process, PKAPC_STATE ApcState);
NTKERNELAPI VOID KeUnstackDetachProcess(PKAPC_STATE ApcState);
NTKERNELAPI NTSTATUS PsLookupProcessByProcessId(HANDLE ProcessId, PEPROCESS *Process);

// ─── GDI types not in kernel headers ──────────────────────────────────────────

typedef PVOID HDC;
typedef PVOID HBITMAP;
typedef PVOID HGDIOBJ;
#ifndef BOOL
typedef int BOOL;
#endif
#define SRCCOPY       0x00CC0020L
#define BI_RGB        0UL
#define DIB_RGB_COLORS 0

#pragma pack(push,1)
typedef struct {
    ULONG  biSize;
    LONG   biWidth;
    LONG   biHeight;
    USHORT biPlanes;
    USHORT biBitCount;
    ULONG  biCompression;
    ULONG  biSizeImage;
    LONG   biXPelsPerMeter;
    LONG   biYPelsPerMeter;
    ULONG  biClrUsed;
    ULONG  biClrImportant;
} CAPT_BITMAPINFOHEADER;

typedef struct {
    UCHAR rgbBlue, rgbGreen, rgbRed, rgbReserved;
} CAPT_RGBQUAD;

typedef struct {
    CAPT_BITMAPINFOHEADER bmiHeader;
    CAPT_RGBQUAD          bmiColors[1];
} CAPT_BITMAPINFO;
#pragma pack(pop)

// ─── ZwQuerySystemInformation classes ────────────────────────────────────────

#define CAPT_SystemModuleInfo    11
#define CAPT_SystemProcessInfo    5

typedef struct {
    HANDLE  Section;
    PVOID   MappedBase;
    PVOID   ImageBase;
    ULONG   ImageSize;
    ULONG   Flags;
    USHORT  LoadOrderIndex;
    USHORT  InitOrderIndex;
    USHORT  LoadCount;
    USHORT  OffsetToFileName;
    UCHAR   FullPathName[256];
} CAPT_MODULE_INFO;

typedef struct {
    ULONG            NumberOfModules;
    CAPT_MODULE_INFO Modules[1];
} CAPT_MODULE_LIST, *PCAPT_MODULE_LIST;

typedef struct {
    ULONG          NextEntryOffset;
    ULONG          NumberOfThreads;
    LARGE_INTEGER  Rsv[6];
    UNICODE_STRING ImageName;
    LONG           BasePriority;
    ULONG          Pad;
    HANDLE         UniqueProcessId;
    HANDLE         InheritedFromId;
    ULONG          HandleCount;
    ULONG          SessionId;
} CAPT_PROC_INFO;

// ─── Inline string helpers ────────────────────────────────────────────────────

static BOOLEAN CaptStrEqA(const char* a, const char* b)
{
    while (*a && *b) { if (*a != *b) return FALSE; a++; b++; }
    return (*a == 0 && *b == 0);
}

static BOOLEAN CaptStrEqIA(const char* a, const char* b)
{
    while (*a && *b) {
        char ca = (*a >= 'A' && *a <= 'Z') ? (char)(*a + 32) : *a;
        char cb = (*b >= 'A' && *b <= 'Z') ? (char)(*b + 32) : *b;
        if (ca != cb) return FALSE;
        a++; b++;
    }
    return (*a == 0 && *b == 0);
}

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

// ─── GRE function types ────────────────────────────────────────────────────────

typedef HDC     (NTAPI *PFN_GreCreateCompatibleDC)(HDC hdc);
typedef HBITMAP (NTAPI *PFN_GreCreateCompatibleBitmap)(HDC hdc, int cx, int cy);
typedef HGDIOBJ (NTAPI *PFN_GreSelectObject)(HDC hdc, HGDIOBJ hobj);
typedef BOOL    (NTAPI *PFN_GreBitBlt)(HDC hdcDst, int x, int y, int cx, int cy,
                                        HDC hdcSrc, int xSrc, int ySrc, ULONG rop);
typedef BOOL    (NTAPI *PFN_GreDeleteDC)(HDC hdc);
typedef BOOL    (NTAPI *PFN_GreDeleteObject)(HGDIOBJ hobj);
typedef int     (NTAPI *PFN_GreGetDIBitsInternal)(HDC hdc, HBITMAP hbm,
                                                   ULONG iStartScan, ULONG cScans,
                                                   PVOID pvBits, PVOID pbmi,
                                                   ULONG iUsage,
                                                   ULONG cjMaxBits, ULONG cjMaxInfo);
typedef LONG    (NTAPI *PFN_GreGetBitmapBits)(HBITMAP hbm, ULONG cjBits, PVOID pvBits);

static PFN_GreCreateCompatibleDC     pfnGreCreateCompatibleDC     = NULL;
static PFN_GreCreateCompatibleBitmap pfnGreCreateCompatibleBitmap = NULL;
static PFN_GreSelectObject           pfnGreSelectObject           = NULL;
static PFN_GreBitBlt                 pfnGreBitBlt                 = NULL;
static PFN_GreDeleteDC               pfnGreDeleteDC               = NULL;
static PFN_GreDeleteObject           pfnGreDeleteObject           = NULL;
static PFN_GreGetDIBitsInternal      pfnGreGetDIBitsInternal      = NULL;
static PFN_GreGetBitmapBits          pfnGreGetBitmapBits          = NULL;

// g_GREAttempted: TRUE after first attempt (so we stop retrying permanently on failure)
// g_GREResolved:  TRUE only when ALL required function ptrs are non-NULL
static BOOLEAN g_GREAttempted = FALSE;
static BOOLEAN g_GREResolved  = FALSE;

static HDC     g_CaptureDC     = NULL;
static HBITMAP g_CaptureBitmap = NULL;
static HGDIOBJ g_OldBitmap     = NULL;

// ─── PE export resolver (skips forwarded exports) ────────────────────────────
//
// A forwarded export's function RVA falls within the export directory's range.
// It points to a string like "win32kfull.GreBitBlt", not to code.
// We SKIP forwarded exports here; the caller tries each win32k* module directly,
// so the real implementation will be found in the exporting module.

static PVOID ResolveExport(PVOID base, const char* funcName)
{
    if (!base || !funcName) return NULL;

    __try {
        PIMAGE_DOS_HEADER dos = (PIMAGE_DOS_HEADER)base;
        if (dos->e_magic != IMAGE_DOS_SIGNATURE) return NULL;

        PIMAGE_NT_HEADERS64 nt = (PIMAGE_NT_HEADERS64)((PUCHAR)base + dos->e_lfanew);
        if (nt->Signature != IMAGE_NT_SIGNATURE) return NULL;

        ULONG expDirRva  = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT].VirtualAddress;
        ULONG expDirSize = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT].Size;
        if (!expDirRva) return NULL;

        PIMAGE_EXPORT_DIRECTORY exp = (PIMAGE_EXPORT_DIRECTORY)((PUCHAR)base + expDirRva);
        PULONG  nameRvas  = (PULONG) ((PUCHAR)base + exp->AddressOfNames);
        PUSHORT ordinals  = (PUSHORT)((PUCHAR)base + exp->AddressOfNameOrdinals);
        PULONG  funcRvas  = (PULONG) ((PUCHAR)base + exp->AddressOfFunctions);

        for (ULONG i = 0; i < exp->NumberOfNames; i++) {
            const char* name = (const char*)((PUCHAR)base + nameRvas[i]);
            if (CaptStrEqA(name, funcName)) {
                ULONG funcRva = funcRvas[ordinals[i]];
                // Skip forwarded exports (RVA inside export directory = string, not code)
                if (funcRva >= expDirRva && funcRva < expDirRva + expDirSize) {
                    DbgPrint("capturedrv: '%s' is forwarded in this module, skipping\n", funcName);
                    return NULL;
                }
                return (PVOID)((PUCHAR)base + funcRva);
            }
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        DbgPrint("capturedrv: exception resolving '%s'\n", funcName);
    }
    return NULL;
}

// Try to resolve funcName from each of the provided module bases in order.
static PVOID TryResolveAny(PVOID* bases, ULONG nBases, const char* funcName)
{
    for (ULONG i = 0; i < nBases; i++) {
        if (!bases[i]) continue;
        PVOID p = ResolveExport(bases[i], funcName);
        if (p) {
            DbgPrint("capturedrv: '%s' = %p (module[%lu])\n", funcName, p, i);
            return p;
        }
    }
    DbgPrint("capturedrv: '%s' NOT FOUND in any win32k module\n", funcName);
    return NULL;
}

// ─── GRE resolution (MUST be called while attached to an interactive session) ─
//
// Called from inside KeStackAttachProcess so that session-space modules
// (win32kfull.sys, win32kbase.sys) appear at their correct session VAs in the
// module list. Sets g_GREResolved = TRUE only if every required ptr is non-NULL.

static BOOLEAN EnsureGREResolved(void)
{
    ULONG sz = 0;
    ZwQuerySystemInformation(CAPT_SystemModuleInfo, NULL, 0, &sz);
    if (!sz) { DbgPrint("capturedrv: sysinfo size=0\n"); return FALSE; }
    sz += 4096;

#pragma warning(suppress:4996)
    PCAPT_MODULE_LIST mods = (PCAPT_MODULE_LIST)ExAllocatePoolWithTag(NonPagedPoolNx, sz, POOL_TAG);
    if (!mods) return FALSE;

    NTSTATUS st = ZwQuerySystemInformation(CAPT_SystemModuleInfo, mods, sz, &sz);
    if (!NT_SUCCESS(st)) {
        ExFreePoolWithTag(mods, POOL_TAG);
        DbgPrint("capturedrv: ZwQuerySystemInformation failed: %08X\n", st);
        return FALSE;
    }

    // Collect bases: [0]=win32k.sys [1]=win32kfull.sys [2]=win32kbase.sys
    PVOID bases[3] = {NULL, NULL, NULL};
    static const char* modNames[3] = {"win32k.sys", "win32kfull.sys", "win32kbase.sys"};
    for (ULONG i = 0; i < mods->NumberOfModules; i++) {
        const char* n = (const char*)mods->Modules[i].FullPathName
                        + mods->Modules[i].OffsetToFileName;
        for (int j = 0; j < 3; j++) {
            if (!bases[j] && CaptStrEqIA(n, modNames[j])) {
                bases[j] = mods->Modules[i].ImageBase;
                DbgPrint("capturedrv: %s @ %p\n", modNames[j], bases[j]);
            }
        }
    }
    ExFreePoolWithTag(mods, POOL_TAG);

    pfnGreCreateCompatibleDC     = (PFN_GreCreateCompatibleDC)    TryResolveAny(bases, 3, "GreCreateCompatibleDC");
    pfnGreCreateCompatibleBitmap = (PFN_GreCreateCompatibleBitmap)TryResolveAny(bases, 3, "GreCreateCompatibleBitmap");
    pfnGreSelectObject           = (PFN_GreSelectObject)          TryResolveAny(bases, 3, "GreSelectObject");
    pfnGreBitBlt                 = (PFN_GreBitBlt)                TryResolveAny(bases, 3, "GreBitBlt");
    pfnGreDeleteDC               = (PFN_GreDeleteDC)              TryResolveAny(bases, 3, "GreDeleteDC");
    pfnGreDeleteObject           = (PFN_GreDeleteObject)          TryResolveAny(bases, 3, "GreDeleteObject");

    // Try GreGetDIBitsInternal first; fall back to GreGetBitmapBits (simpler, no BITMAPINFO)
    pfnGreGetDIBitsInternal = (PFN_GreGetDIBitsInternal)TryResolveAny(bases, 3, "GreGetDIBitsInternal");
    if (!pfnGreGetDIBitsInternal)
        pfnGreGetBitmapBits = (PFN_GreGetBitmapBits)TryResolveAny(bases, 3, "GreGetBitmapBits");

    BOOLEAN ok = pfnGreCreateCompatibleDC  != NULL &&
                 pfnGreCreateCompatibleBitmap != NULL &&
                 pfnGreSelectObject        != NULL &&
                 pfnGreBitBlt              != NULL &&
                 pfnGreDeleteDC            != NULL &&
                 (pfnGreGetDIBitsInternal  != NULL || pfnGreGetBitmapBits != NULL);

    DbgPrint("capturedrv: GRE %s  CDC=%p CBC=%p SO=%p BB=%p "
             "DelDC=%p GetDIB=%p GetBits=%p\n",
        ok ? "OK" : "FAIL",
        pfnGreCreateCompatibleDC, pfnGreCreateCompatibleBitmap,
        pfnGreSelectObject, pfnGreBitBlt, pfnGreDeleteDC,
        pfnGreGetDIBitsInternal, pfnGreGetBitmapBits);

    return ok;
}

// ─── Find a PID in the interactive (non-zero) session ─────────────────────────

static HANDLE FindInteractiveSessionPid(void)
{
    ULONG bufSize = 0x20000;
    PVOID buf = NULL;

    for (int attempt = 0; attempt < 3; attempt++) {
#pragma warning(suppress:4996)
        buf = ExAllocatePoolWithTag(NonPagedPoolNx, bufSize, POOL_TAG);
        if (!buf) return NULL;

        NTSTATUS st = ZwQuerySystemInformation(CAPT_SystemProcessInfo, buf, bufSize, &bufSize);
        if (NT_SUCCESS(st)) break;

        ExFreePoolWithTag(buf, POOL_TAG);
        buf = NULL;
        if (st != STATUS_INFO_LENGTH_MISMATCH) return NULL;
        bufSize += 0x10000;
    }
    if (!buf) return NULL;

    HANDLE pid = NULL;
    CAPT_PROC_INFO* entry = (CAPT_PROC_INFO*)buf;
    for (;;) {
        if (entry->SessionId > 0 && entry->UniqueProcessId != NULL) {
            pid = entry->UniqueProcessId;
            break;
        }
        if (entry->NextEntryOffset == 0) break;
        entry = (CAPT_PROC_INFO*)((PUCHAR)entry + entry->NextEntryOffset);
    }

    ExFreePoolWithTag(buf, POOL_TAG);
    DbgPrint("capturedrv: interactive session PID = %p\n", pid);
    return pid;
}

// ─── GRE resource cleanup (must be called while attached to the same session) ─

static void FreeCaptureResources(void)
{
    if (pfnGreDeleteObject && g_CaptureBitmap) {
        if (g_OldBitmap && pfnGreSelectObject && g_CaptureDC)
            pfnGreSelectObject(g_CaptureDC, g_OldBitmap);
        pfnGreDeleteObject((HGDIOBJ)g_CaptureBitmap);
        g_CaptureBitmap = NULL;
        g_OldBitmap     = NULL;
    }
    if (pfnGreDeleteDC && g_CaptureDC) {
        pfnGreDeleteDC(g_CaptureDC);
        g_CaptureDC = NULL;
    }
}

// ─── Init capture DC and bitmap (must be called while attached to session) ────

static NTSTATUS InitCaptureDCs(void)
{
    FreeCaptureResources();

    // Compatible DC with the display (NULL = primary display format reference)
    g_CaptureDC = pfnGreCreateCompatibleDC(NULL);
    if (!g_CaptureDC) {
        DbgPrint("capturedrv: GreCreateCompatibleDC(NULL) failed\n");
        return STATUS_UNSUCCESSFUL;
    }

    g_CaptureBitmap = pfnGreCreateCompatibleBitmap(g_CaptureDC, (int)g_FrameWidth, (int)g_FrameHeight);
    if (!g_CaptureBitmap) {
        DbgPrint("capturedrv: GreCreateCompatibleBitmap failed\n");
        pfnGreDeleteDC(g_CaptureDC); g_CaptureDC = NULL;
        return STATUS_UNSUCCESSFUL;
    }

    g_OldBitmap = pfnGreSelectObject(g_CaptureDC, (HGDIOBJ)g_CaptureBitmap);
    DbgPrint("capturedrv: capture DC=%p bmp=%p\n", g_CaptureDC, g_CaptureBitmap);
    return STATUS_SUCCESS;
}

// ─── Capture a frame ─────────────────────────────────────────────────────────

static NTSTATUS CaptureFrame(void)
{
    // Find a Session 1 process to attach to
    HANDLE sessionPid = FindInteractiveSessionPid();
    if (!sessionPid) {
        DbgPrint("capturedrv: no interactive session process found\n");
        return STATUS_NO_SUCH_PRIVILEGE;
    }

    PEPROCESS sessionProc = NULL;
    NTSTATUS st = PsLookupProcessByProcessId(sessionPid, &sessionProc);
    if (!NT_SUCCESS(st)) {
        DbgPrint("capturedrv: PsLookupProcessByProcessId failed: %08X\n", st);
        return st;
    }

    // Attach to the session 1 process — gives us session context and correct VAs
    KAPC_STATE apcState;
    KeStackAttachProcess(sessionProc, &apcState);

    __try {
        // ── Resolve GRE on first call, while in session context ───────────────
        // CRITICAL: g_GREAttempted prevents infinite retry on permanent failure.
        // g_GREResolved is set TRUE only when ALL function ptrs are non-NULL.
        if (!g_GREAttempted) {
            g_GREAttempted = TRUE;
            g_GREResolved  = EnsureGREResolved();
        }
        if (!g_GREResolved) {
            st = STATUS_NOT_FOUND;
            __leave;
        }

        // ── Init capture resources if needed ──────────────────────────────────
        if (!g_CaptureDC || !g_CaptureBitmap) {
            st = InitCaptureDCs();
            if (!NT_SUCCESS(st)) __leave;
        }

        // ── BitBlt: NULL source DC = read from primary display (GRE path) ─────
        // Passing NULL as source HDC in a kernel GRE call reads from the
        // physical display surface, below DWM's WDA_EXCLUDEFROMCAPTURE filter.
        BOOL ok = pfnGreBitBlt(
            g_CaptureDC, 0, 0, (int)g_FrameWidth, (int)g_FrameHeight,
            NULL,  // source: physical screen (bypasses WDA at GRE level)
            0, 0, SRCCOPY);

        if (!ok) {
            DbgPrint("capturedrv: GreBitBlt failed (source=NULL)\n");
            st = STATUS_UNSUCCESSFUL;
            __leave;
        }

        // ── Extract pixels from the capture bitmap ────────────────────────────
        if (g_FrameBuffer) {
            int rows = 0;

            if (pfnGreGetDIBitsInternal) {
                // Full DIB extraction with explicit format — preferred path
                CAPT_BITMAPINFO bmi = {{0}};
                bmi.bmiHeader.biSize        = sizeof(CAPT_BITMAPINFOHEADER);
                bmi.bmiHeader.biWidth       = (LONG)g_FrameWidth;
                bmi.bmiHeader.biHeight      = -(LONG)g_FrameHeight; // top-down
                bmi.bmiHeader.biPlanes      = 1;
                bmi.bmiHeader.biBitCount    = 32;
                bmi.bmiHeader.biCompression = BI_RGB;
                bmi.bmiHeader.biSizeImage   = g_FrameSize;
                rows = pfnGreGetDIBitsInternal(
                    g_CaptureDC, g_CaptureBitmap,
                    0, g_FrameHeight,
                    g_FrameBuffer, &bmi, DIB_RGB_COLORS,
                    g_FrameSize, sizeof(bmi));
            } else if (pfnGreGetBitmapBits) {
                // Fallback: raw bitmap bits (BGRA for 32-bit screen on Win11)
                rows = (int)pfnGreGetBitmapBits(g_CaptureBitmap, g_FrameSize, g_FrameBuffer);
            }

            if (rows == 0) {
                DbgPrint("capturedrv: pixel extraction returned 0 rows\n");
                st = STATUS_UNSUCCESSFUL;
                __leave;
            }
            DbgPrint("capturedrv: captured %d rows\n", rows);
        }

        st = STATUS_SUCCESS;

    } __except (EXCEPTION_EXECUTE_HANDLER) {
        DbgPrint("capturedrv: exception in CaptureFrame: %08X\n", GetExceptionCode());
        st = STATUS_ACCESS_VIOLATION;
        // Invalidate cached DCs since they may be in a bad state
        g_CaptureDC     = NULL;
        g_CaptureBitmap = NULL;
        g_OldBitmap     = NULL;
    }

    KeUnstackDetachProcess(&apcState);
    ObDereferenceObject(sessionProc);

    if (NT_SUCCESS(st))
        KeSetEvent(&g_FrameReady, IO_NO_INCREMENT, FALSE);

    return st;
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

    PIO_STACK_LOCATION stack  = IoGetCurrentIrpStackLocation(Irp);
    ULONG    code   = stack->Parameters.DeviceIoControl.IoControlCode;
    NTSTATUS status = STATUS_SUCCESS;
    ULONG_PTR info  = 0;

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

    case IOCTL_CAPTURE_SET_RESOLUTION:
    {
        if (stack->Parameters.DeviceIoControl.InputBufferLength < sizeof(CAPTURE_RESOLUTION)) {
            status = STATUS_BUFFER_TOO_SMALL; break;
        }
        PCAPTURE_RESOLUTION req = (PCAPTURE_RESOLUTION)Irp->AssociatedIrp.SystemBuffer;
        if (req->Width  == 0 || req->Height == 0 ||
            req->Width  > CAPTURE_MAX_WIDTH || req->Height > CAPTURE_MAX_HEIGHT) {
            status = STATUS_INVALID_PARAMETER; break;
        }

        KIRQL irql;
        KeAcquireSpinLock(&g_FrameLock, &irql);
        g_FrameWidth  = req->Width;
        g_FrameHeight = req->Height;
        g_FrameStride = g_FrameWidth  * CAPTURE_BPP;
        g_FrameSize   = g_FrameStride * g_FrameHeight;
        if (g_FrameBuffer) {
            ExFreePoolWithTag(g_FrameBuffer, POOL_TAG);
            g_FrameBuffer = NULL;
        }
        // Mark DCs invalid; FreeCaptureResources needs session context, so
        // just null the pointers here — they'll be reinitialised on next capture.
        g_CaptureDC = NULL; g_CaptureBitmap = NULL; g_OldBitmap = NULL;
        KeReleaseSpinLock(&g_FrameLock, irql);
        break;
    }

    case IOCTL_CAPTURE_GET_FRAME:
    {
        if (!g_FrameBuffer) {
            ULONG needed = g_FrameStride * g_FrameHeight;
#pragma warning(suppress:4996)
            g_FrameBuffer = ExAllocatePoolWithTag(NonPagedPoolNx, needed, POOL_TAG);
            if (!g_FrameBuffer) { status = STATUS_INSUFFICIENT_RESOURCES; break; }
        }

        status = CaptureFrame();
        if (!NT_SUCCESS(status)) break;

        if (!Irp->MdlAddress) { status = STATUS_INVALID_PARAMETER; break; }

        PVOID userBuf = MmGetSystemAddressForMdlSafe(Irp->MdlAddress, NormalPagePriority);
        if (!userBuf) { status = STATUS_INSUFFICIENT_RESOURCES; break; }

        ULONG outLen = stack->Parameters.DeviceIoControl.OutputBufferLength;
        if (outLen < g_FrameSize) { status = STATUS_BUFFER_TOO_SMALL; break; }

        KIRQL irql;
        KeAcquireSpinLock(&g_FrameLock, &irql);
        if (g_FrameBuffer) {
            RtlCopyMemory(userBuf, g_FrameBuffer, g_FrameSize);
            info = g_FrameSize;
        } else {
            status = STATUS_DEVICE_NOT_READY;
        }
        KeReleaseSpinLock(&g_FrameLock, irql);
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

    UNICODE_STRING sym = RTL_CONSTANT_STRING(CAPTUREDRV_SYMLINK);
    IoDeleteSymbolicLink(&sym);

    if (g_DeviceObject) {
        IoDeleteDevice(g_DeviceObject);
        g_DeviceObject = NULL;
    }

    if ((g_CaptureDC || g_CaptureBitmap) && g_GREResolved) {
        HANDLE pid = FindInteractiveSessionPid();
        PEPROCESS proc = NULL;
        if (pid && NT_SUCCESS(PsLookupProcessByProcessId(pid, &proc))) {
            KAPC_STATE apc;
            KeStackAttachProcess(proc, &apc);
            FreeCaptureResources();
            KeUnstackDetachProcess(&apc);
            ObDereferenceObject(proc);
        }
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

    DbgPrint("capturedrv: DriverEntry start\n");

    KeInitializeEvent(&g_FrameReady, NotificationEvent, FALSE);
    KeInitializeSpinLock(&g_FrameLock);

    g_FrameWidth  = 1920;
    g_FrameHeight = 1080;
    g_FrameStride = g_FrameWidth  * CAPTURE_BPP;
    g_FrameSize   = g_FrameStride * g_FrameHeight;

    UNICODE_STRING devName = RTL_CONSTANT_STRING(CAPTUREDRV_DEVICE_NAME);
    NTSTATUS st = IoCreateDevice(
        DriverObject, 0, &devName,
        FILE_DEVICE_UNKNOWN, FILE_DEVICE_SECURE_OPEN,
        FALSE, &g_DeviceObject);

    if (!NT_SUCCESS(st)) {
        DbgPrint("capturedrv: IoCreateDevice failed: %08X\n", st);
        return st;
    }

    UNICODE_STRING symLink = RTL_CONSTANT_STRING(CAPTUREDRV_SYMLINK);
    st = IoCreateSymbolicLink(&symLink, &devName);
    if (!NT_SUCCESS(st)) {
        DbgPrint("capturedrv: IoCreateSymbolicLink failed: %08X\n", st);
        IoDeleteDevice(g_DeviceObject);
        return st;
    }

    DriverObject->DriverUnload                          = CaptureDriverUnload;
    DriverObject->MajorFunction[IRP_MJ_CREATE]         = CaptureDispatchCreate;
    DriverObject->MajorFunction[IRP_MJ_CLOSE]          = CaptureDispatchClose;
    DriverObject->MajorFunction[IRP_MJ_DEVICE_CONTROL] = CaptureDispatchDeviceControl;

    g_DeviceObject->Flags |= DO_BUFFERED_IO;
    g_DeviceObject->Flags &= ~DO_DEVICE_INITIALIZING;

    DbgPrint("capturedrv: Loaded OK. GRE resolution deferred to first IOCTL.\n");
    return STATUS_SUCCESS;
}
