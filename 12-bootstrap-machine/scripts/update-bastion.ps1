# Download the latest lab on this Windows machine and copy it to a bastion with no GitHub access.
# Does not delete env, values.local.yaml, create-cluster.env, registry/, airgap/, or kubeconfigs
# already on the bastion. Those files are not in the public archive.
#
#   powershell -ExecutionPolicy Bypass -File .\update-bastion.ps1 -Target ubuntu@<bastion-ip>
#Requires -Version 5.1
param(
    [Parameter(Mandatory = $true)]
    [string]$Target
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$work = Join-Path $env:TEMP ("nkp-labs-update-" + [guid]::NewGuid().ToString("n"))
New-Item -ItemType Directory -Force -Path $work | Out-Null
try {
    $archive = Join-Path $work "src.tar.gz"
    Write-Host "=== downloading latest nkp-labs main ==="
    curl.exe -fL --retry 5 -o $archive "https://codeload.github.com/fernandoquinino-ntx/nkp-labs/tar.gz/refs/heads/main"
    tar -xzf $archive -C $work
    $src = Get-ChildItem -Directory $work -Filter "nkp-labs-*" | Select-Object -First 1
    $lab = Join-Path $src.FullName "12-bootstrap-machine"
    if (-not (Test-Path (Join-Path $lab "scripts"))) { throw "archive has no 12-bootstrap-machine/scripts" }
    Write-Host "=== copying to ${Target}:/home/ubuntu/nkp-workspace/ ==="
    scp -r (Join-Path $lab "*") "${Target}:/home/ubuntu/nkp-workspace/"
    if ($LASTEXITCODE -ne 0) { throw "scp failed ($LASTEXITCODE)" }
    Write-Host "=== done. Secrets and airgap/registry data on the bastion were not in this copy. ==="
}
finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
