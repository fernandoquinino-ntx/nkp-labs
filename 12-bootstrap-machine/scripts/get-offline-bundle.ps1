# One command on a Windows client: download the latest offline bundle from the public
# GitHub release, check its sha256, and print the copy command. No login.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\get-offline-bundle.ps1 [OUT_DIR]
#
# Without that release it builds the bundle here when bash and Docker are installed.
#Requires -Version 5.1
param(
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
# PowerShell 7 turns a native command's stderr into an error. gh writes progress there.
if (Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}
$Lab = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $Lab 'dist' }
$Repo = if ($env:NKP_LABS_GH_REPO) { $env:NKP_LABS_GH_REPO } else { 'fernandoquinino-ntx/nkp-labs' }

$hostScript = Get-Content -Raw (Join-Path $PSScriptRoot 'bootstrap-host.sh')
if ($hostScript -match 'NKP_VERSION="\$\{NKP_VERSION:-([^}]+)\}"') {
    $Version = $Matches[1]
} else {
    throw "could not read NKP_VERSION from bootstrap-host.sh"
}
$Name = "nkp-bootstrap-offline-$Version-noble-amd64"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$base = "https://github.com/$Repo/releases/download/offline-bundle"
$file = Join-Path $OutDir "$Name.tar.gz"
$sumFile = "$file.sha256"
$ProgressPreference = 'SilentlyContinue'
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}
Write-Host "=== $base/$Name.tar.gz ==="
$downloaded = $false
try {
    Invoke-WebRequest -Uri "$base/$Name.tar.gz" -OutFile $file -UseBasicParsing
    Invoke-WebRequest -Uri "$base/$Name.tar.gz.sha256" -OutFile $sumFile -UseBasicParsing
    Invoke-WebRequest -Uri "$base/cloud-init-offline.yaml" -OutFile (Join-Path $OutDir 'cloud-init-offline.yaml') -UseBasicParsing
    $downloaded = $true
} catch {
    Write-Host "the public release is not there yet ($($_.Exception.Message))"
    Remove-Item -Force $file, $sumFile -ErrorAction SilentlyContinue
}
if ($downloaded) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead((Resolve-Path -LiteralPath $file).ProviderPath)
    try {
        $got = ([BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '').ToLowerInvariant()
    } finally {
        $stream.Dispose()
        $sha.Dispose()
    }
    $expected = ((Get-Content -Raw $sumFile) -split '\s+')[0].ToLower()
    if ($got -ne $expected) {
        Remove-Item -Force $file
        throw "checksum mismatch for $file. Run the command again."
    }
    $size = [Math]::Round((Get-Item $file).Length / 1MB)
    Write-Host "$file ($size MB), sha256 ok"
    Write-Host "copy it with Windows OpenSSH:"
    Write-Host "  scp `"$file`" ubuntu@<bootstrap-ip>:/home/ubuntu/"
    return
}

$bash = Get-Command bash -ErrorAction SilentlyContinue
$docker = Get-Command docker -ErrorAction SilentlyContinue
if ($bash -and $docker) {
    Write-Host "=== building the bundle here instead (needs Docker) ==="
    & bash (Join-Path $PSScriptRoot 'build-offline-bundle.sh') $OutDir
    if ($LASTEXITCODE -ne 0) { throw "build-offline-bundle.sh failed ($LASTEXITCODE)" }
    return
}
throw "could not download the bundle. Install and log in to gh, or install Docker and bash to build it."
