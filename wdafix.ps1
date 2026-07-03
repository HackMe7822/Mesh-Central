# wdafix.ps1 — run from MeshCentral terminal (SYSTEM/Session 0)
# Spawns a helper into the interactive session (Session 1) that clears
# SetWindowDisplayAffinity on all BrowserLock windows every 2 seconds.
# Works indefinitely in the background; BrowserLock re-sets WDA on startup
# so the loop keeps clearing it.

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class S0Spawn {
    [DllImport("kernel32")] public static extern uint WTSGetActiveConsoleSessionId();
    [DllImport("wtsapi32")] public static extern bool WTSQueryUserToken(uint s, out IntPtr t);
    [DllImport("kernel32")] public static extern bool CloseHandle(IntPtr h);
    [DllImport("advapi32", SetLastError=true, CharSet=CharSet.Auto)]
    public static extern bool CreateProcessAsUser(
        IntPtr hToken, string app, string cmd,
        IntPtr pAttr, IntPtr tAttr, bool inherit,
        uint flags, IntPtr env, string dir,
        ref STARTUPINFO si, out PROCINFO pi);
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Auto)]
    public struct STARTUPINFO {
        public int cb; public string lpReserved, lpDesktop, lpTitle;
        public uint dwX,dwY,dwXSize,dwYSize,dwXCountChars,dwYCountChars,dwFillAttribute,dwFlags;
        public ushort wShowWindow,cbReserved2;
        public IntPtr lpReserved2,hStdInput,hStdOutput,hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct PROCINFO {
        public IntPtr hProcess,hThread; public uint dwProcessId,dwThreadId;
    }
}
"@ -EA Stop

# Inner script — runs inside Session 1, loops forever clearing WDA
$inner = @'
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class WdaLoop {
    public delegate bool WNDENUMPROC(IntPtr hw, IntPtr lp);
    [DllImport("user32")] public static extern bool EnumWindows(WNDENUMPROC f, IntPtr lp);
    [DllImport("user32")] public static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
    [DllImport("user32")] public static extern bool SetWindowDisplayAffinity(IntPtr h, uint a);
    [DllImport("user32")] public static extern bool GetWindowDisplayAffinity(IntPtr h, out uint a);
}
"@ -EA Stop

$log = "C:\Windows\Temp\wda_fix.log"
"Started $(Get-Date)" | Out-File $log

while ($true) {
    $blPids = @((Get-Process BrowserLock -EA 0).Id)
    if ($blPids.Count -gt 0) {
        $cleared = 0
        $cb = [WdaLoop+WNDENUMPROC]{
            param($hw, $lp)
            $p = [int]0
            [WdaLoop]::GetWindowThreadProcessId($hw, [ref]$p) | Out-Null
            if ($script:blPids -contains $p) {
                $aff = [uint32]0
                [WdaLoop]::GetWindowDisplayAffinity($hw, [ref]$aff) | Out-Null
                if ($aff -ne 0) {
                    [WdaLoop]::SetWindowDisplayAffinity($hw, 0) | Out-Null
                    $script:cleared++
                    "$(Get-Date -f HH:mm:ss) CLEARED HWND=$hw PID=$p WDA_was=$aff" | Out-File $log -Append
                }
            }
            return $true
        }
        [WdaLoop]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
        if ($cleared -gt 0) {
            "$(Get-Date -f HH:mm:ss) Cleared WDA on $cleared window(s)" | Out-File $log -Append
        }
    }
    Start-Sleep -Seconds 2
}
'@

$enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
$cmdLine = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $enc"

$sid = [S0Spawn]::WTSGetActiveConsoleSessionId()
$tok = [IntPtr]::Zero
$gotTok = [S0Spawn]::WTSQueryUserToken($sid, [ref]$tok)
Write-Host "ActiveSession=$sid WTSQueryUserToken=$gotTok Token=$tok"

if (-not $gotTok -or $tok -eq [IntPtr]::Zero) {
    Write-Host "ERROR: Cannot get user token. Are you running as SYSTEM?"
    exit 1
}

$si = New-Object S0Spawn+STARTUPINFO
$si.cb = [Runtime.InteropServices.Marshal]::SizeOf($si)
$si.lpDesktop = "WinSta0\Default"
$pi = New-Object S0Spawn+PROCINFO

$ok = [S0Spawn]::CreateProcessAsUser(
    $tok, $null, $cmdLine,
    [IntPtr]::Zero, [IntPtr]::Zero, $false,
    0x08000000,   # CREATE_NO_WINDOW
    [IntPtr]::Zero, $null,
    [ref]$si, [ref]$pi)

Write-Host "Launched Session-1 WDA-clear loop: ok=$ok PID=$($pi.dwProcessId)"
[S0Spawn]::CloseHandle($tok) | Out-Null
if ($ok) {
    [S0Spawn]::CloseHandle($pi.hProcess) | Out-Null
    [S0Spawn]::CloseHandle($pi.hThread) | Out-Null
    Write-Host "Background helper running in Session $sid."
    Write-Host "Log: C:\Windows\Temp\wda_fix.log"
    Write-Host "After ~5 seconds, refresh the KVM view to check if screen is visible."
}
