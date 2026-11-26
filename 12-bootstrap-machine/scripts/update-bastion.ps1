# Download the latest lab on this Windows machine and copy it to a bastion with no GitHub access.
# Does not delete env, values.local.yaml, create-cluster.env, registry/, airgap/, or kubeconfigs
# already on the bastion. Those files are not in the public archive.
#
#   powershell -ExecutionPolicy Bypass -File .\update-bastion.ps1 -Target ubuntu@<bastion-ip>
#   powershell -ExecutionPolicy Bypass -File .\update-bastion.ps1 -Target ubuntu@<bastion-ip> -DryRun
#   powershell -ExecutionPolicy Bypass -File .\update-bastion.ps1 -Target ubuntu@<bastion-ip> -Rollback
#Requires -Version 5.1
param(
    [Parameter(Mandatory = $true)]
    [string]$Target,
    [switch]$DryRun,
    [switch]$Rollback
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}
$repo = if ($env:NKP_LABS_GH_REPO) { $env:NKP_LABS_GH_REPO } else { 'fernandoquinino-ntx/nkp-labs' }
$releaseBase = "https://github.com/$repo/releases/download/offline-bundle"

if ($Rollback) {
    Write-Host "=== rolling back ${Target}:~/nkp-workspace from ~/.nkp-workspace-backup/prev ==="
    $rbCmd = 'set -euo pipefail; [ -d ~/.nkp-workspace-backup/prev ] || { echo "no backup at ~/.nkp-workspace-backup/prev" >&2; exit 1; }; cp -a ~/.nkp-workspace-backup/prev/. ~/nkp-workspace/; chmod 0755 ~/nkp-workspace/scripts/*.sh ~/nkp-workspace/scripts/*.py 2>/dev/null || true; echo "rolled back ~/nkp-workspace"'
    & ssh -o StrictHostKeyChecking=accept-new $Target $rbCmd
    if ($LASTEXITCODE -ne 0) { throw "rollback failed ($LASTEXITCODE)" }
    return
}

$work = Join-Path $env:TEMP ("nkp-labs-update-" + [guid]::NewGuid().ToString("n"))
New-Item -ItemType Directory -Force -Path $work | Out-Null
try {
    $payload = Join-Path $work "nkp-labs-update.tar.gz"
    $sumFile = Join-Path $work "nkp-labs-update.tar.gz.sha256"
    $commit = "main"
    $sourceLabel = ""
    $usedRelease = $false

    try {
        Write-Host "=== downloading nkp-labs-update.tar.gz from offline-bundle release ==="
        Invoke-WebRequest -UseBasicParsing -Uri "$releaseBase/nkp-labs-update.tar.gz" -OutFile $payload
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "$releaseBase/nkp-labs-update.tar.gz.sha256" -OutFile $sumFile
            $expected = ((Get-Content -Raw $sumFile) -split '\s+')[0].ToLower()
            $got = (Get-FileHash -Algorithm SHA256 $payload).Hash.ToLower()
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
        & tar -C $srcDir.FullName -czf $payload "12-bootstrap-machine"
        if ($LASTEXITCODE -ne 0) { throw "repack failed ($LASTEXITCODE)" }
        $sourceLabel = "github:${repo}@main"
    }

    if ($DryRun) {
        $sizeKb = [Math]::Round((Get-Item $payload).Length / 1KB)
        Write-Host "=== dry-run: would transfer nkp-labs-update.tar.gz (${sizeKb} KB, commit=$commit, source=$sourceLabel) to ${Target}:~/nkp-workspace ==="
        & tar -tzf $payload | Select-String '/scripts/' | ForEach-Object { Write-Host "  $_" }
        return
    }

    $remoteTmp = "/tmp/nkp-labs-update-$PID.tar.gz"
    Write-Host "=== transferring archive to ${Target}:${remoteTmp} (commit=$commit) ==="
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
printf 'commit=%s\nupdated_at=%s\nmode=bastion-push-win\nsource=%s\n' '${commit}' "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" '${sourceLabel}' > ~/nkp-workspace/.nkp-labs-version
if sudo -n true 2>/dev/null && [ -d /usr/local/lib/nkp-bootstrap ]; then
  for f in bootstrap-host.sh expand-root-disk.sh update-workspace.sh; do
    [ -f ~/nkp-workspace/scripts/\${f} ] && sudo install -m 0755 ~/nkp-workspace/scripts/\${f} /usr/local/lib/nkp-bootstrap/\${f}
  done
fi
echo "updated \$(find ~/nkp-workspace/scripts -maxdepth 1 \( -name '*.sh' -o -name '*.py' \) | wc -l) executable scripts (commit=${commit})"
"@
    $remoteCmdLf = $remoteCmd -replace "`r`n", "`n"
    & ssh -o StrictHostKeyChecking=accept-new $Target $remoteCmdLf
    if ($LASTEXITCODE -ne 0) { throw "remote extract failed ($LASTEXITCODE)" }
    Write-Host "=== done. Secrets and airgap/registry data on the bastion were not touched. ==="
}
finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
