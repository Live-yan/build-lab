$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$NodeVersion = if ($env:NODE_VERSION) { $env:NODE_VERSION } else { "24.18.1" }
$NodeRedVersion = if ($env:NODE_RED_VERSION) { $env:NODE_RED_VERSION } else { "5.0.1" }
$ModbusVersion = if ($env:MODBUS_VERSION) { $env:MODBUS_VERSION } else { "5.60.1" }
$OpcUaVersion = if ($env:OPCUA_VERSION) { $env:OPCUA_VERSION } else { "0.2.354" }
$KafkaVersion = if ($env:KAFKA_VERSION) { $env:KAFKA_VERSION } else { "6.1.1" }

$RootDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$DistDir = Join-Path $RootDir "dist-node-red-windows"
$PackageName = "NodeRED-Windows-x64"
$PackageDir = Join-Path $DistDir $PackageName
$WorkDir = Join-Path $DistDir ".work"

if (Test-Path $DistDir) {
    Remove-Item $DistDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $PackageDir, $WorkDir | Out-Null
New-Item -ItemType Directory -Force -Path `
    (Join-Path $PackageDir "runtime"), `
    (Join-Path $PackageDir "app"), `
    (Join-Path $PackageDir "data"), `
    (Join-Path $PackageDir "logs") | Out-Null

$NodeArchive = "node-v$NodeVersion-win-x64.zip"
$NodeUrl = "https://nodejs.org/dist/v$NodeVersion/$NodeArchive"
$ShasumUrl = "https://nodejs.org/dist/v$NodeVersion/SHASUMS256.txt"
$NodeArchivePath = Join-Path $WorkDir $NodeArchive
$ShasumPath = Join-Path $WorkDir "SHASUMS256.txt"

Invoke-WebRequest -Uri $NodeUrl -OutFile $NodeArchivePath -UseBasicParsing
Invoke-WebRequest -Uri $ShasumUrl -OutFile $ShasumPath -UseBasicParsing

$ExpectedLine = Get-Content $ShasumPath | Where-Object { $_ -match "\s+$([regex]::Escape($NodeArchive))$" } | Select-Object -First 1
if (-not $ExpectedLine) {
    throw "Could not find SHA256 for $NodeArchive"
}
$ExpectedHash = ($ExpectedLine -split '\s+')[0].ToUpperInvariant()
$ActualHash = (Get-FileHash -Algorithm SHA256 $NodeArchivePath).Hash.ToUpperInvariant()
if ($ExpectedHash -ne $ActualHash) {
    throw "Node.js archive SHA256 mismatch. Expected $ExpectedHash, got $ActualHash"
}

$ExtractDir = Join-Path $WorkDir "node"
Expand-Archive -Path $NodeArchivePath -DestinationPath $ExtractDir -Force
$ExtractedRoot = Join-Path $ExtractDir "node-v$NodeVersion-win-x64"
Copy-Item (Join-Path $ExtractedRoot "*") (Join-Path $PackageDir "runtime") -Recurse -Force

$NodeExe = Join-Path $PackageDir "runtime\node.exe"
$NpmCmd = Join-Path $PackageDir "runtime\npm.cmd"
& $NodeExe --version
& $NpmCmd --version

$AppPackageJson = @"
{
  "name": "node-red-offline-runtime",
  "private": true,
  "version": "1.0.0",
  "dependencies": {
    "node-red": "$NodeRedVersion"
  }
}
"@
Set-Content -Path (Join-Path $PackageDir "app\package.json") -Value $AppPackageJson -Encoding UTF8

Push-Location (Join-Path $PackageDir "app")
try {
    & $NpmCmd install --omit=dev --no-audit --no-fund
    if ($LASTEXITCODE -ne 0) { throw "npm install failed for Node-RED runtime" }
    & $NpmCmd ls --depth=0
    if ($LASTEXITCODE -ne 0) { throw "npm ls failed for Node-RED runtime" }
}
finally {
    Pop-Location
}

$DataPackageJson = @"
{
  "name": "node-red-offline-userdir",
  "private": true,
  "version": "1.0.0",
  "dependencies": {
    "@oriolrius/node-red-contrib-kafka": "$KafkaVersion",
    "node-red-contrib-modbus": "$ModbusVersion",
    "node-red-contrib-opcua": "$OpcUaVersion"
  }
}
"@
Set-Content -Path (Join-Path $PackageDir "data\package.json") -Value $DataPackageJson -Encoding UTF8

Push-Location (Join-Path $PackageDir "data")
try {
    & $NpmCmd install --omit=dev --no-audit --no-fund
    if ($LASTEXITCODE -ne 0) { throw "npm install failed for Node-RED protocol nodes" }
    & $NpmCmd ls --depth=0
    if ($LASTEXITCODE -ne 0) { throw "npm ls failed for Node-RED protocol nodes" }
}
finally {
    Pop-Location
}

$Settings = @'
const settings = {
    uiHost: process.env.NODE_RED_HOST || "0.0.0.0",
    uiPort: Number(process.env.NODE_RED_PORT || 1880),
    flowFile: "flows.json",
    flowFilePretty: true,
    logging: {
        console: {
            level: process.env.NODE_RED_LOG_LEVEL || "info",
            metrics: false,
            audit: false
        }
    },
    editorTheme: {
        projects: { enabled: false }
    }
};

if (process.env.NODE_RED_CREDENTIAL_SECRET) {
    settings.credentialSecret = process.env.NODE_RED_CREDENTIAL_SECRET;
}

module.exports = settings;
'@
Set-Content -Path (Join-Path $PackageDir "data\settings.js") -Value $Settings -Encoding UTF8
Set-Content -Path (Join-Path $PackageDir "data\flows.json") -Value "[]" -Encoding UTF8

$StartCmd = @'
@echo off
setlocal
set "ROOT=%~dp0"
if "%NODE_RED_HOST%"=="" set "NODE_RED_HOST=0.0.0.0"
if "%NODE_RED_PORT%"=="" set "NODE_RED_PORT=1880"
start "" cmd /c "timeout /t 2 /nobreak ^>nul ^& start http://127.0.0.1:%NODE_RED_PORT%"
"%ROOT%runtime\node.exe" "%ROOT%app\node_modules\node-red\red.js" --userDir "%ROOT%data" %*
endlocal
'@
Set-Content -Path (Join-Path $PackageDir "start-node-red.cmd") -Value $StartCmd -Encoding ASCII

$StartNoBrowserCmd = @'
@echo off
setlocal
set "ROOT=%~dp0"
if "%NODE_RED_HOST%"=="" set "NODE_RED_HOST=0.0.0.0"
if "%NODE_RED_PORT%"=="" set "NODE_RED_PORT=1880"
"%ROOT%runtime\node.exe" "%ROOT%app\node_modules\node-red\red.js" --userDir "%ROOT%data" %*
endlocal
'@
Set-Content -Path (Join-Path $PackageDir "start-node-red-no-browser.cmd") -Value $StartNoBrowserCmd -Encoding ASCII

$CheckCmd = @'
@echo off
setlocal
set "ROOT=%~dp0"
"%ROOT%runtime\node.exe" --version
if errorlevel 1 exit /b 1
"%ROOT%runtime\npm.cmd" --version
if errorlevel 1 exit /b 1
echo Architecture: Windows x64
echo Environment check: PASS
endlocal
'@
Set-Content -Path (Join-Path $PackageDir "check-environment.cmd") -Value $CheckCmd -Encoding ASCII

$Readme = @"
Node-RED Offline Portable Package - Windows x64
================================================

Target:
  - Windows 10/11 or Windows Server x64
  - No Internet required at runtime
  - No separately installed Node.js/npm required

Bundled versions:
  Node.js: $NodeVersion
  Node-RED: $NodeRedVersion
  Modbus: node-red-contrib-modbus $ModbusVersion
  OPC UA: node-red-contrib-opcua $OpcUaVersion
  Kafka: @oriolrius/node-red-contrib-kafka $KafkaVersion

Built-in Node-RED nodes also provide MQTT, HTTP, TCP, UDP and WebSocket support.

Run:
  1. Double-click check-environment.cmd
  2. Double-click start-node-red.cmd
  3. Browser opens http://127.0.0.1:1880

For server/headless use, run start-node-red-no-browser.cmd.
Other machines can use http://<windows-ip>:1880 when Windows Firewall permits TCP/1880.

Optional environment variables:
  NODE_RED_HOST=0.0.0.0
  NODE_RED_PORT=1880
  NODE_RED_LOG_LEVEL=info
  NODE_RED_CREDENTIAL_SECRET=<your-secret>

All npm dependencies and Node.js are already included. Do NOT run npm install on the offline target.

Security note:
  The portable package intentionally does not ship a fixed default administrator password.
  Node-RED's editor therefore has no admin authentication by default. Restrict TCP/1880 with
  Windows Firewall and configure Node-RED adminAuth before exposing it to untrusted networks.
"@
Set-Content -Path (Join-Path $PackageDir "README-OFFLINE.txt") -Value $Readme -Encoding UTF8

$VersionText = @"
Package: NodeRED-Windows-x64
Build architecture: windows-x64
Node.js: $NodeVersion
Node-RED: $NodeRedVersion
node-red-contrib-modbus: $ModbusVersion
node-red-contrib-opcua: $OpcUaVersion
@oriolrius/node-red-contrib-kafka: $KafkaVersion
"@
Set-Content -Path (Join-Path $PackageDir "VERSION.txt") -Value $VersionText -Encoding UTF8

Remove-Item $WorkDir -Recurse -Force

$ZipPath = Join-Path $DistDir "node-red-offline-windows-x64.zip"
Compress-Archive -Path (Join-Path $PackageDir "*") -DestinationPath $ZipPath -CompressionLevel Optimal -Force
$ZipHash = (Get-FileHash -Algorithm SHA256 $ZipPath).Hash.ToLowerInvariant()
Set-Content -Path "$ZipPath.sha256" -Value "$ZipHash  $(Split-Path $ZipPath -Leaf)" -Encoding ASCII

Write-Host "Windows Node-RED offline package prepared at: $ZipPath"
