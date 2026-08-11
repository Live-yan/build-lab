param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot "..\dist"),
    [int]$JavaVersion = 25
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$distRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot $OutputDirectory))
$packageDir = Join-Path $distRoot "KafbatUI"
$tempDir = Join-Path $distRoot "_tmp"

if (Test-Path $distRoot) {
    Remove-Item $distRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $packageDir -Force | Out-Null
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $packageDir "data") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $packageDir "data\uploads") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $packageDir "logs") -Force | Out-Null

$githubHeaders = @{
    Accept = "application/vnd.github+json"
    "User-Agent" = "kafbat-ui-offline-windows-builder"
    "X-GitHub-Api-Version" = "2022-11-28"
}
if ($env:GITHUB_TOKEN) {
    $githubHeaders.Authorization = "Bearer $($env:GITHUB_TOKEN)"
}

Write-Host "Resolving latest Kafbat UI release..."
$release = Invoke-RestMethod `
    -Uri "https://api.github.com/repos/kafbat/kafka-ui/releases/latest" `
    -Headers $githubHeaders

$jarAssets = @($release.assets | Where-Object { $_.name -match '^api-v.*\.jar$' })
if ($jarAssets.Count -eq 0) {
    $jarAssets = @($release.assets | Where-Object { $_.name -match '\.jar$' })
}
if ($jarAssets.Count -eq 0) {
    throw "No executable JAR asset was found in Kafbat UI release $($release.tag_name)."
}

$jarAsset = $jarAssets[0]
$jarPath = Join-Path $packageDir "api.jar"
Write-Host "Downloading Kafbat UI $($release.tag_name): $($jarAsset.name)"
Invoke-WebRequest -Uri $jarAsset.browser_download_url -OutFile $jarPath

if ($jarAsset.PSObject.Properties.Name -contains "digest" -and $jarAsset.digest -match '^sha256:(.+)$') {
    $expected = $Matches[1].ToLowerInvariant()
    $actual = (Get-FileHash -Path $jarPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        throw "Kafbat UI JAR SHA256 mismatch. Expected $expected, got $actual."
    }
    Write-Host "Kafbat UI JAR SHA256 verified."
}

Write-Host "Resolving Eclipse Temurin JRE $JavaVersion for Windows x64..."
$adoptiumUrl = "https://api.adoptium.net/v3/assets/latest/$JavaVersion/hotspot?architecture=x64&image_type=jre&os=windows"
$javaAssets = @(Invoke-RestMethod -Uri $adoptiumUrl -Headers @{ "User-Agent" = "kafbat-ui-offline-windows-builder" })
$javaAsset = @($javaAssets | Where-Object { $_.binary.package.link })[0]
if (-not $javaAsset) {
    throw "No Windows x64 JRE $JavaVersion package was returned by Eclipse Adoptium."
}

$jreZip = Join-Path $tempDir "jre.zip"
Write-Host "Downloading JRE: $($javaAsset.binary.package.name)"
Invoke-WebRequest -Uri $javaAsset.binary.package.link -OutFile $jreZip

if ($javaAsset.binary.package.checksum) {
    $expected = ([string]$javaAsset.binary.package.checksum).ToLowerInvariant()
    $actual = (Get-FileHash -Path $jreZip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        throw "JRE SHA256 mismatch. Expected $expected, got $actual."
    }
    Write-Host "JRE SHA256 verified."
}

$jreExtract = Join-Path $tempDir "jre-extracted"
Expand-Archive -Path $jreZip -DestinationPath $jreExtract -Force
$jreRoot = Get-ChildItem -Path $jreExtract -Directory | Select-Object -First 1
if (-not $jreRoot) {
    throw "JRE archive did not contain an expected top-level directory."
}

$jreDir = Join-Path $packageDir "jre"
New-Item -ItemType Directory -Path $jreDir -Force | Out-Null
Copy-Item -Path (Join-Path $jreRoot.FullName "*") -Destination $jreDir -Recurse -Force

$javaExe = Join-Path $jreDir "bin\java.exe"
if (-not (Test-Path $javaExe)) {
    throw "Packaged JRE is invalid: bin\java.exe was not found."
}

$startBat = @'
@echo off
setlocal
cd /d "%~dp0"

if not exist "data" mkdir "data"
if not exist "data\uploads" mkdir "data\uploads"
if not exist "logs" mkdir "logs"

set "DYNAMIC_CONFIG_ENABLED=true"
set "DYNAMIC_CONFIG_PATH=%CD%\data\dynamic_config.yaml"
set "CONFIG_RELATED_UPLOADS_DIR=%CD%\data\uploads"
set "SERVER_PORT=8080"

cls
echo ============================================================
echo                 Kafbat UI - Offline Windows
echo ============================================================
echo.
echo Web UI: http://localhost:8080
echo.
echo Kafka cluster information can be configured in the web UI.
echo Configuration is persisted under: %CD%\data
echo.
echo Keep this window open while using Kafbat UI.
echo Press Ctrl+C or close this window to stop the service.
echo ============================================================
echo.

"%~dp0jre\bin\java.exe" --add-opens java.rmi/javax.rmi.ssl=ALL-UNNAMED -jar "%~dp0api.jar"

if errorlevel 1 (
  echo.
  echo Kafbat UI exited with an error.
  pause
)
endlocal
'@
Set-Content -Path (Join-Path $packageDir "start.bat") -Value $startBat -Encoding ASCII

$readmeText = @"
Kafbat UI Offline Package for Windows x64
=========================================

Kafbat UI version: $($release.tag_name)
Java runtime: Eclipse Temurin JRE $JavaVersion (Windows x64, HotSpot)

Usage
-----
1. Extract this package to a normal writable directory, for example D:\KafkaUI.
2. Double-click start.bat.
3. Open http://localhost:8080 in a browser.
4. Use the Kafbat UI Configuration Wizard to add your Kafka cluster.

Persistence
-----------
Web UI cluster configuration is stored under the local data directory:
  data\dynamic_config.yaml

Uploaded truststores/keystores and related files are stored under:
  data\uploads

To keep your Kafka configuration, keep the data directory when replacing the
program with a newer offline package.

Stopping
--------
Press Ctrl+C in the Kafbat UI console window or close that console window.

Notes
-----
- No Docker Desktop is required.
- No system-wide Java installation is required.
- The included JRE is used only by this package.
- The offline computer does not need Internet access to start Kafbat UI.
"@
Set-Content -Path (Join-Path $packageDir "README.txt") -Value $readmeText -Encoding UTF8

$jarSha256 = (Get-FileHash -Path $jarPath -Algorithm SHA256).Hash
$jreSha256 = (Get-FileHash -Path $jreZip -Algorithm SHA256).Hash
$versionText = @"
KAFBAT_UI_VERSION=$($release.tag_name)
KAFBAT_UI_ASSET=$($jarAsset.name)
KAFBAT_UI_JAR_SHA256=$jarSha256
JAVA_DISTRIBUTION=Eclipse Temurin
JAVA_FEATURE_VERSION=$JavaVersion
JAVA_PACKAGE=$($javaAsset.binary.package.name)
JAVA_ARCHIVE_SHA256=$jreSha256
BUILD_UTC=$([DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"))
"@
Set-Content -Path (Join-Path $packageDir "VERSION.txt") -Value $versionText -Encoding ASCII

Remove-Item $tempDir -Recurse -Force

Write-Host ""
Write-Host "Offline package prepared successfully:"
Write-Host "  $packageDir"
Write-Host "  Kafbat UI: $($release.tag_name)"
Write-Host "  JRE: $($javaAsset.binary.package.name)"
