@echo off
setlocal

set CL_EXE=C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Tools\MSVC\14.51.36231\bin\Hostx64\x64\cl.exe
set LINK_EXE=C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Tools\MSVC\14.51.36231\bin\Hostx64\x64\link.exe

set WDK_KM=C:\Program Files (x86)\Windows Kits\10\Include\10.0.28000.0\km
set WDK_SH=C:\Program Files (x86)\Windows Kits\10\Include\10.0.26100.0\shared
set WDK_UC=C:\Program Files (x86)\Windows Kits\10\Include\10.0.26100.0\ucrt
set VC_INC=C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Tools\MSVC\14.51.36231\include

set WDK_LIB=C:\Program Files (x86)\Windows Kits\10\Lib\10.0.28000.0\km\x64
set VC_LIB=C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Tools\MSVC\14.51.36231\lib\x64

set INCLUDE=%WDK_KM%;%WDK_SH%;%WDK_UC%;%VC_INC%
set LIB=%WDK_LIB%;%VC_LIB%

echo [*] Compiling capturedrv.c ...
"%CL_EXE%" /nologo /kernel /W3 /WX- /Od ^
    /D_WIN64 /D_AMD64_ /DWIN32 /DNDEBUG ^
    /D_WIN32_WINNT=0x0A00 /DNTDDI_VERSION=0x0A000000 ^
    /GS- /Gz /c capturedrv.c /Focapturedrv.obj
if %ERRORLEVEL% NEQ 0 (
    echo [!] Compile failed.
    goto :end
)

echo [*] Linking capturedrv.sys ...
"%LINK_EXE%" /nologo /SUBSYSTEM:NATIVE /DRIVER:WDM ^
    /ENTRY:DriverEntry /ALIGN:4096 ^
    /NODEFAULTLIB /STACK:0x40000,0x1000 ^
    /OUT:capturedrv.sys ^
    capturedrv.obj ^
    "%WDK_LIB%\ntoskrnl.lib" ^
    "%WDK_LIB%\hal.lib" ^
    "%WDK_LIB%\wdm.lib"
if %ERRORLEVEL% NEQ 0 (
    echo [!] Link failed.
    goto :end
)

echo [+] Build succeeded: capturedrv.sys

:end
endlocal
