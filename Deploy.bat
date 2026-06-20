@echo off
title Creations IT - Remote Support Deployer

:: Self-elevate to Administrator if not already
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting Administrator privileges...
    powershell -Command "Start-Process cmd -ArgumentList '/c \"%~f0\"' -Verb RunAs -Wait"
    exit /b
)

echo.
echo  ============================================
echo    Creations IT  -  Remote Support Deployer
echo  ============================================
echo.
echo  Downloading latest installer from GitHub...
echo.

powershell -ExecutionPolicy Bypass -Command "$u=(iwr 'https://api.github.com/repos/HackMe7822/Mesh-Central/contents/install.ps1' -UseBasicParsing|ConvertFrom-Json).download_url; iwr $u -OutFile 'C:\deploy.ps1'"

powershell -ExecutionPolicy Bypass -File "C:\deploy.ps1"

echo.
pause
