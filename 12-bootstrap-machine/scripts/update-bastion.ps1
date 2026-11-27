# Download the latest lab on this Windows machine and copy it to a bastion with no GitHub access.
# Checks the bastion's currently installed version and enforces the 3-previous-versions
# backward-compatibility policy (same MAJOR, up to 3 minor versions behind) before updating.
# Does not delete env, values.local.yaml, create-cluster.env, registry/, airgap/, or kubeconfigs
# already on the bastion.
#
#   powershell -ExecutionPolicy Bypass -File .\update-bastion.ps1 -Target ubuntu@<bastion-ip>
#   powershell -ExecutionPolicy Bypass -File .\update-bastion.ps1 -Target ubuntu@<bastion-ip> -DryRun
#   powershell -ExecutionPolicy Bypass -File .\update-bastion.ps1 -Target ubuntu@<bastion-ip> -Rollback
#   powershell -ExecutionPolicy Bypass -File .\update-bastion.ps1 -Target ubuntu@<bastion-ip> -Force
#Requires -Version 5.1
param(
    [Parameter(Mandatory = $true)]
    [string]$Target,
    [switch]$DryRun,
    [switch]$Rollback,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}
$repo = if ($env:NKP_LABS_GH_REPO) { $env:NKP_LABS_GH_REPO } else { 'fernandoquinino-ntx/nkp-labs' }
$releaseBase = if ($env:NKP_LABS_RELEASE_BASE) { $env:NKP_LABS_RELEASE_BASE.TrimEnd('/') } else { "https://github.com/$repo/releases/download/offline-bundle" }

function Test-BackwardCompat {
    param(
        [string]$Installed,
        [string]$TargetVersion,
        [int]$Window = 3,
        [bool]$AllowForce = $false
    )
    if (-not $TargetVersion -or $TargetVersion -eq 'unknown') {
        Write-Host "=== Compatibility check: bastion=$Installed -> target=unknown (proceeding) ==="
        return
    }
    if (-not $Installed -or $Installed -eq 'none') {
        Write-Host "=== Compatibility check: fresh bastion -> target $TargetVersion -- BACKWARD-COMPATIBLE (initial install) ==="
        return
    }
    if ($Installed -notmatch '^(\d+)\.(\d+)\.(\d+)$') {
        if ($AllowForce) { Write-Warning "Invalid installed version '$Installed'; overridden by -Force."; return }
        throw "Compatibility check: bastion '$Installed' -> target '$TargetVersion' -- NOT BACKWARD-COMPATIBLE. Pass -Force to override."
    }
    $cMaj = [int]$Matches[1]; $cMin = [int]$Matches[2]
    if ($TargetVersion -notmatch '^(\d+)\.(\d+)\.(\d+)$') {
        if ($AllowForce) { Write-Warning "Invalid target version '$TargetVersion'; overridden by -Force."; return }
        throw "Compatibility check: bastion '$Installed' -> target '$TargetVersion' -- NOT BACKWARD-COMPATIBLE. Pass -Force to override."
    }
    $tMaj = [int]$Matches[1]; $tMin = [int]$Matches[2]
    if ($cMaj -ne $tMaj) {
        $msg = "Compatibility check: bastion $Installed -> target $TargetVersion (major mismatch) -- NOT BACKWARD-COMPATIBLE."
        if ($AllowForce) { Write-Warning "$msg Overridden by -Force."; return }
        throw "$msg Automatic update blocked. Pass -Force to override."
    }
    $delta = $tMin - $cMin
    if ($delta -lt 0) {
        $msg = "Compatibility check: bastion $Installed -> target $TargetVersion (downgrade by $(-$delta) minor version(s)) -- NOT BACKWARD-COMPATIBLE."
        if ($AllowForce) { Write-Warning "$msg Overridden by -Force."; return }
        throw "$msg Use -Rollback or pass -Force to override."
    }
    if ($delta -le $Window) {
        Write-Host "=== Compatibility check: bastion $Installed -> target $TargetVersion ($delta version(s) behind, max allowed: $Window) -- BACKWARD-COMPATIBLE ==="
        return
    }
    $msg = "Compatibility check: bastion $Installed -> target $TargetVersion ($delta version(s) behind, max allowed: $Window) -- NOT BACKWARD-COMPATIBLE."
    if ($AllowForce) {
        Write-Warning "$msg Overridden by -Force."
        return
    }
    throw "$msg Automatic update blocked: only up to $Window previous versions are guaranteed backward-compatible. Upgrade via an intermediate version or pass -Force."
}

if ($Rollback) {
    Write-Host "=== rolling back ${Target}:~/nkp-workspace from ~/.nkp-workspace-backup/prev ==="
    $rbCmd = 'set -euo pipefail; [ -d ~/.nkp-workspace-backup/prev ] || { echo "no backup at ~/.nkp-workspace-backup/prev" >&2; exit 1; }; cp -a ~/.nkp-workspace-backup/prev/. ~/nkp-workspace/; chmod 0755 ~/nkp-workspace/scripts/*.sh ~/nkp-workspace/scripts/*.py 2>/dev/null || true; echo "rolled back ~/nkp-workspace"'
    & ssh -o StrictHostKeyChecking=accept-new $Target $rbCmd
    if ($LASTEXITCODE -ne 0) { throw "rollback failed ($LASTEXITCODE)" }
    return
}

function Get-Sha256Hex([string]$Path) {
    $full = (Resolve-Path -LiteralPath $Path).ProviderPath
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($full)
    try {
        $bytes = $sha.ComputeHash($stream)
        return ([BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
    } finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}

$work = Join-Path $env:TEMP ("nkp-labs-update-" + [guid]::NewGuid().ToString("n"))
New-Item -ItemType Directory -Force -Path $work | Out-Null
try {
    $payload = Join-Path $work "nkp-labs-update.tar.gz"
    $sumFile = Join-Path $work "nkp-labs-update.tar.gz.sha256"
    $commit = "main"
    $targetVersion = "unknown"
    $compatWindow = 3
    $sourceLabel = ""
    $usedRelease = $false

    try {
        Write-Host "=== downloading nkp-labs-update.tar.gz from offline-bundle release ==="
        Invoke-WebRequest -UseBasicParsing -Uri "$releaseBase/nkp-labs-update.tar.gz" -OutFile $payload
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "$releaseBase/nkp-labs-update.tar.gz.sha256" -OutFile $sumFile
            $expected = ((Get-Content -Raw $sumFile) -split '\s+')[0].ToLower()
            $got = Get-Sha256Hex $payload
            if ($got -ne $expected) {
                throw "sha256 mismatch for nkp-labs-update.tar.gz (expected $expected, got $got)"
            }
            Write-Host "    sha256 ok ($got)"
        } catch {
            if ($_.Exception.Message -like '*sha256 mismatch*') { throw }
        }
        try {
            $mfResp = Invoke-WebRequest -UseBasicParsing -Uri "$releaseBase/MANIFEST.json"
            $mfText = if ($mfResp.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($mfResp.Content) } else { [string]$mfResp.Content }
            $mf = $mfText | ConvertFrom-Json
            if ($mf.git_sha) { $commit = [string]$mf.git_sha }
            if ($mf.lab_version) { $targetVersion = [string]$mf.lab_version }
            if ($mf.compat_window) { $compatWindow = [int]$mf.compat_window }
        } catch {}
        $sourceLabel = "release:offline-bundle"
        $usedRelease = $true
    } catch {
        if ($_.Exception.Message -like '*sha256 mismatch*') { throw }
        Write-Host "=== release unavailable; falling back to GitHub $repo main ==="
        $rawArchive = Join-Path $work "src.tar.gz"
        & curl.exe -fL --retry 5 -o $rawArchive "https://codeload.github.com/$repo/tar.gz/refs/heads/main"
        if ($LASTEXITCODE -ne 0) { throw "download failed ($LASTEXITCODE)" }
        & tar -xzf $rawArchive -C $work
        $srcDir = Get-ChildItem -Directory $work -Filter "nkp-labs-*" | Select-Object -First 1
        if (-not $srcDir -or -not (Test-Path (Join-Path $srcDir.FullName "12-bootstrap-machine\scripts"))) {
            throw "archive has no 12-bootstrap-machine/scripts"
        }
        $verEnvPath = Join-Path $srcDir.FullName "12-bootstrap-machine\versions.env"
        if (Test-Path $verEnvPath) {
            $vRaw = Get-Content -Raw $verEnvPath
            if ($vRaw -match '(?m)^LAB_VERSION="?([^"#\r\n]+)"?') { $targetVersion = $Matches[1].Trim() }
            if ($vRaw -match '(?m)^LAB_COMPAT_WINDOW="?(\d+)"?') { $compatWindow = [int]$Matches[1] }
        }
        & tar -C $srcDir.FullName -czf $payload "12-bootstrap-machine"
        if ($LASTEXITCODE -ne 0) { throw "repack failed ($LASTEXITCODE)" }
        $sourceLabel = "github:${repo}@main"
    }

    if ($targetVersion -eq 'unknown') {
        $probeDir = Join-Path $work "probe"
        New-Item -ItemType Directory -Force -Path $probeDir | Out-Null
        & tar -xzf $payload -C $probeDir "12-bootstrap-machine/versions.env" 2>$null
        $vFile = Join-Path $probeDir "12-bootstrap-machine\versions.env"
        if (Test-Path $vFile) {
            $vRaw = Get-Content -Raw $vFile
            if ($vRaw -match '(?m)^LAB_VERSION="?([^"#\r\n]+)"?') { $targetVersion = $Matches[1].Trim() }
            if ($vRaw -match '(?m)^LAB_COMPAT_WINDOW="?(\d+)"?') { $compatWindow = [int]$Matches[1] }
        }
    }

    Write-Host "=== checking currently installed version on $Target ==="
    $probeCmd = 'v=""; [ -f ~/nkp-workspace/.nkp-labs-version ] && v="$(awk -F= "\$1 == \"lab_version\" {print \$2; exit}" ~/nkp-workspace/.nkp-labs-version 2>/dev/null || true)"; if [ -z "$v" ] && [ -f ~/nkp-workspace/versions.env ]; then v="$(awk -F= "\$1 == \"LAB_VERSION\" {gsub(/\"/, \"\", \$2); print \$2; exit}" ~/nkp-workspace/versions.env 2>/dev/null || true)"; fi; if [ -z "$v" ]; then if [ -f ~/nkp-workspace/scripts/create-prism-role.ps1 ]; then v="1.2.0"; elif [ -f ~/nkp-workspace/scripts/setup-local-registry.sh ]; then v="1.1.0"; elif [ -d ~/nkp-workspace/scripts ]; then v="1.0.0"; else v="none"; fi; fi; printf "%s" "$v"'
    $remoteVer = (& ssh -o StrictHostKeyChecking=accept-new $Target $probeCmd)
    if ($LASTEXITCODE -ne 0 -or -not $remoteVer) { $remoteVer = 'none' }
    $remoteVer = ([string]$remoteVer).Trim()

    Test-BackwardCompat -Installed $remoteVer -TargetVersion $targetVersion -Window $compatWindow -AllowForce ([bool]$Force)

    if ($DryRun) {
        $sizeKb = [Math]::Round((Get-Item $payload).Length / 1KB)
        Write-Host "=== dry-run: would transfer nkp-labs-update.tar.gz (${sizeKb} KB, version=$targetVersion, commit=$commit, source=$sourceLabel) to ${Target}:~/nkp-workspace ==="
        & tar -tzf $payload | Select-String '/scripts/' | ForEach-Object { Write-Host "  $_" }
        return
    }

    $remoteTmp = "/tmp/nkp-labs-update-$PID.tar.gz"
    Write-Host "=== transferring archive to ${Target}:${remoteTmp} (version=$targetVersion, commit=$commit) ==="
    & scp -o StrictHostKeyChecking=accept-new $payload "${Target}:${remoteTmp}"
    if ($LASTEXITCODE -ne 0) { throw "scp failed ($LASTEXITCODE)" }

    Write-Host "=== extracting on ${Target}:~/nkp-workspace (preserving local env/registry/airgap/kubeconfigs) ==="
    $remoteCmd = @"
set -euo pipefail
mkdir -p ~/nkp-workspace ~/.nkp-workspace-backup
if [ -d ~/nkp-workspace/scripts ]; then
  rm -rf ~/.nkp-workspace-backup/prev.new && mkdir -p ~/.nkp-workspace-backup/prev.new
  tar -C ~/nkp-workspace --exclude='./env' --exclude='./values.local.yaml' --exclude='./create-cluster.env' \
    --exclude='./kommander.yaml' --exclude='./registry' --exclude='./airgap' --exclude='./*.kubeconfig' \
    -cf - . 2>/dev/null | tar -C ~/.nkp-workspace-backup/prev.new -xf - 2>/dev/null || true
  rm -rf ~/.nkp-workspace-backup/prev && mv ~/.nkp-workspace-backup/prev.new ~/.nkp-workspace-backup/prev
fi
tar -xzf '${remoteTmp}' --strip-components=1 -C ~/nkp-workspace
rm -f '${remoteTmp}'
chmod 0755 ~/nkp-workspace/scripts/*.sh ~/nkp-workspace/scripts/*.py 2>/dev/null || true
printf 'lab_version=%s\ncommit=%s\nupdated_at=%s\nmode=bastion-push-win\nsource=%s\n' '${targetVersion}' '${commit}' "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" '${sourceLabel}' > ~/nkp-workspace/.nkp-labs-version
if sudo -n true 2>/dev/null && [ -d /usr/local/lib/nkp-bootstrap ]; then
  for f in bootstrap-host.sh expand-root-disk.sh update-workspace.sh; do
    [ -f ~/nkp-workspace/scripts/\${f} ] && sudo install -m 0755 ~/nkp-workspace/scripts/\${f} /usr/local/lib/nkp-bootstrap/\${f}
  done
fi
echo "updated \$(find ~/nkp-workspace/scripts -maxdepth 1 \( -name '*.sh' -o -name '*.py' \) | wc -l) executable scripts (version=${targetVersion}, commit=${commit})"
"@
    $remoteCmdLf = $remoteCmd -replace "`r`n", "`n"
    & ssh -o StrictHostKeyChecking=accept-new $Target $remoteCmdLf
    if ($LASTEXITCODE -ne 0) { throw "remote extract failed ($LASTEXITCODE)" }
    Write-Host "=== done. Secrets and airgap/registry data on the bastion were not touched. ==="
}
finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
