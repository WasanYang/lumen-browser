# Publishes MiniBrowser and builds the installer into installer\Output.
# Needs Inno Setup 6: winget install JRSoftware.InnoSetup
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$publish = "$root\bin\installer-publish"

# Always publish into an empty folder: publishing again over a previous single-file publish
# leaves out WebView2Loader.dll, blocklist.txt and Extensions (tested), so the app crashes on start.
if (Test-Path $publish) { Remove-Item $publish -Recurse -Force }
dotnet publish "$root\MiniBrowser.csproj" -c Release -r win-x64 --self-contained false -p:PublishSingleFile=true -o $publish
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$iscc = @(
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw 'ISCC.exe not found. Install Inno Setup 6: winget install JRSoftware.InnoSetup' }

& $iscc "$PSScriptRoot\MiniBrowser.iss"
exit $LASTEXITCODE
