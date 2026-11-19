# One command on a Windows client: download the latest offline bundle that CI built
# from main, check its sha256, and print the push command.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\get-offline-bundle.ps1 [OUT_DIR]
#
# Needs the GitHub CLI, logged in once:  winget install GitHub.cli ; gh auth login
# Without gh it builds the bundle here when bash and Docker are installed.
#Requires -Version 5.1
param(
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
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

function Invoke-Gh {
    & gh @args
    if ($LASTEXITCODE -ne 0) { throw "gh $($args -join ' ') failed ($LASTEXITCODE)" }
}

$gh = Get-Command gh -ErrorAction SilentlyContinue
$loggedIn = $false
if ($gh) {
    & gh auth status *> $null
    $loggedIn = $LASTEXITCODE -eq 0
}

if ($loggedIn) {
    $raw = Invoke-Gh run list -R $Repo --workflow offline-bundle.yml --branch main --status success --limit 1 --json databaseId,headSha,createdAt
    $runs = @($raw | ConvertFrom-Json)
    if ($runs -and $runs[0].databaseId) {
        $run = $runs[0]
        $commit = $run.headSha.Substring(0, [Math]::Min(7, $run.headSha.Length))
        Write-Host "=== CI run $($run.databaseId), commit $commit, built $($run.createdAt) ==="
        foreach ($ext in '.tar.gz', '.tar.gz.sha256') {
            $old = Join-Path $OutDir ($Name + $ext)
            if (Test-Path $old) { Remove-Item -Force $old }
        }
        Invoke-Gh run download $run.databaseId -R $Repo -n $Name -D $OutDir
        $file = Join-Path $OutDir "$Name.tar.gz"
        $sumFile = Join-Path $OutDir "$Name.tar.gz.sha256"
        if (-not (Test-Path $file) -or -not (Test-Path $sumFile)) {
            throw "the CI artifact did not contain $Name.tar.gz and its .sha256"
        }
        $got = (Get-FileHash -Algorithm SHA256 $file).Hash.ToLower()
        $expected = ((Get-Content -Raw $sumFile) -split '\s+')[0].ToLower()
        if ($got -ne $expected) {
            Remove-Item -Force $file
            throw "checksum mismatch for $file. Run the command again."
        }
        $size = [Math]::Round((Get-Item $file).Length / 1MB)
        Write-Host "$file ($size MB), sha256 ok"
        Write-Host "next (bash): $Lab/scripts/push-offline-bundle.sh $file ubuntu@<bootstrap-ip> --follow"
        Write-Host "or copy it with Windows OpenSSH:"
        Write-Host "  scp `"$file`" ubuntu@<bootstrap-ip>:/home/ubuntu/"
        return
    }
    Write-Host "no successful offline-bundle CI run on $Repo main"
} else {
    Write-Host "gh is not installed or not logged in. Install it with: winget install GitHub.cli"
    Write-Host "Then: gh auth login"
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
