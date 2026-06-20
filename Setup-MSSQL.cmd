@echo off
net session >nul 2>&1
if %errorLevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)
powershell -ExecutionPolicy Bypass -Command "$u=(Invoke-WebRequest 'https://api.github.com/repos/HackMe7822/Mesh-Central/contents/setup-mssql.ps1' -UseBasicParsing|ConvertFrom-Json).download_url; Invoke-WebRequest $u -OutFile 'C:\setup-mssql.ps1' -UseBasicParsing; powershell -ExecutionPolicy Bypass -File 'C:\setup-mssql.ps1'"
