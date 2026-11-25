# Ask for the Prism Central IP, the role name, and the NKP user, then create
# (or update) that role with the full source-code-verified NKP 2.19 permissions
# (CAREN preflight + CAPX v1.10 + CCM + IPAM + Nutanix CSI 3.9, including PC
# 7.3/7.5+ renamed/v4 operations and recursive relatedOperationList predecessor
# resolution) and create (or update) its Authorization Policy.
# The user must already exist. Passwords are never printed or saved.
#
#   powershell -ExecutionPolicy Bypass -File .\create-prism-role.ps1
#
# Optional non-interactive parameters (prompted when omitted):
#   -PrismIp <ip-or-url> -RoleName <name> -NkpUser <user>
#   -AdminUser <admin> -AdminPassword <pass> -PcVersion <auto|7.5|7.3|2024.3>
#   -ApiVersion <v4.0|v4.1.b3|...> -NkpPassword <pass> -PrintOnly
#Requires -Version 5.1
param(
    [string]$PrismIp,
    [string]$RoleName,
    [string]$NkpUser,
    [string]$AdminUser,
    [string]$AdminPassword,
    [string]$PcVersion,
    [string]$ApiVersion,
    [string]$NkpPassword,
    [switch]$PrintOnly
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 6) {
    if ([int][Net.ServicePointManager]::SecurityProtocol -ne 0) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }
    if (-not ([System.Management.Automation.PSTypeName]'NkpTrustAllCerts').Type) {
        Add-Type -TypeDefinition @'
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;

public static class NkpTrustAllCerts {
    public static void Enable() {
        ServicePointManager.ServerCertificateValidationCallback =
            delegate(object sender, X509Certificate cert, X509Chain chain, SslPolicyErrors errors) {
                return true;
            };
    }
}
'@
    }
    [NkpTrustAllCerts]::Enable()
}

function Read-Required([string]$Prompt, [string]$Default) {
    $suffix = ""
    if ($Default) { $suffix = " [$Default]" }
    $value = Read-Host "$Prompt$suffix"
    if (-not $value) { $value = $Default }
    if (-not $value) { throw "$Prompt is required" }
    return $value.Trim()
}

function Resolve-BaseUrl([string]$InputHost) {
    $v = $InputHost.Trim().TrimEnd('/')
    if ($v -notmatch '^https?://') {
        if ($v -match ':\d+$') { $v = "https://$v" }
        else { $v = "https://${v}:9440" }
    } else {
        $uri = [Uri]$v
        if ($uri.IsDefaultPort -and $v -notmatch ':\d+$') {
            $v = "$($uri.Scheme)://$($uri.Host):9440$($uri.AbsolutePath.TrimEnd('/'))"
        }
    }
    return $v.TrimEnd('/')
}

function Parse-PcVersion([string]$Raw) {
    if (-not $Raw) { return $null }
    $clean = $Raw.Trim()
    if ($clean -match '(\d+)\.(\d+)(?:\.(\d+))?') {
        $maj = [int]$Matches[1]
        $min = [int]$Matches[2]
        $pat = if ($Matches[3]) { [int]$Matches[3] } else { 0 }
        return @{
            Raw        = $clean
            Major      = $maj
            Minor      = $min
            Patch      = $pat
            IsPc73Plus = ($maj -ge 7 -and $maj -lt 2000 -and ($maj -gt 7 -or $min -ge 3))
            IsPc75Plus = ($maj -ge 7 -and $maj -lt 2000 -and ($maj -gt 7 -or $min -ge 5))
        }
    }
    return $null
}

Write-Host "Prism Central role for NKP 2.19 (CAREN + CAPX + CCM + IPAM + CSI 3.9)"
$ip = if ($PrismIp) { $PrismIp.Trim() } else { Read-Required "Prism Central IP" }
$roleName = if ($RoleName) { $RoleName.Trim() } else { Read-Required "Role name" "NKP Cluster Create" }
if (-not $PrintOnly) {
    $nkpUser = if ($NkpUser) { $NkpUser.Trim() } else { Read-Required "NKP user (must already exist in Prism Central)" }
}
$admin = if ($AdminUser) { $AdminUser.Trim() } else { Read-Required "Prism Central admin user" "admin" }
if (-not $AdminPassword) {
    $secure = Read-Host "Prism Central admin password" -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $adminPass = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
} else {
    $adminPass = $AdminPassword
}
if (-not $adminPass) { throw "Prism Central admin password is required" }

$policyName = "$roleName policy"
$base = Resolve-BaseUrl $ip
$pair = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${admin}:${adminPass}"))
$adminPass = $null
$AdminPassword = $null

$nkpAuthPair = $null
if ($NkpPassword -and $nkpUser) {
    $nkpAuthPair = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${nkpUser}:${NkpPassword}"))
    $NkpPassword = $null
}

# Source-code-verified permission matrix covering:
#   - CAREN preflight webhooks (ValidateCredentials -> Users.List, DomainManager.List/Products,
#     Clusters, StorageContainers, Images, Subnets, AvailabilityZones)
#   - CAPX v1.9/v1.10 (VMs, VMProfiles, GPUs, Categories, Projects, ResourceGroups, Tasks,
#     VolumeGroups, ProtectionPolicies, RecoveryPlans)
#   - CCM (DomainManager, Clusters, ClusterHost, Projects, ResourceGroups, Categories, VMs)
#   - Nutanix IPAM provider (Subnets, Reserve/Unreserve Subnet IP)
#   - Nutanix CSI 3.7/3.9 (Storage Containers / View Container, Volume Groups, Recovery Points)
# across Prism Central 2024.x, pc.7.3, pc.7.5, and pc.7.6+.
#
# EVERY listed operation name that exists (and is EXTERNAL/assignable) on this Prism Central
# is added (both legacy v3 and v4/pc.7.3+ renamed operation names), and relatedOperationList
# predecessors are resolved recursively below.
# MinPc: "" = optional, "all" = always required, "7.3" = required on PC 7.3+, "7.5" = required on PC 7.5+
$permissions = @(
    # --- CAREN Preflight, IAM & Prism Central Domain Manager ---
    @{ Name = "View User";                                   MinPc = "7.5" },
    @{ Name = "View Domain Manager";                         MinPc = "7.5" },
    @{ Name = "View Domain Manager Product";                 MinPc = "" },
    @{ Name = "View Prism Central";                          MinPc = "" },
    @{ Name = "View Task";                                   MinPc = "7.3" },
    @{ Name = "Fetch Task Response";                         MinPc = "" },
    @{ Name = "View Availability Zone";                      MinPc = "" },

    # --- AHV VM & VM Profiles (v4 + legacy v3) ---
    @{ Name = "Create New Virtual Machine";                  MinPc = "7.3" },
    @{ Name = "Create Virtual Machine";                      MinPc = "" },
    @{ Name = "Delete Existing Virtual Machine";             MinPc = "7.3" },
    @{ Name = "Delete Virtual Machine";                      MinPc = "" },
    @{ Name = "View Existing Virtual Machine";               MinPc = "7.3" },
    @{ Name = "View Virtual Machine";                        MinPc = "" },
    @{ Name = "Update Virtual Machine";                      MinPc = "" },
    @{ Name = "Update Virtual Machine Basic Config";         MinPc = "" },
    @{ Name = "Update Virtual Machine Custom Attributes";    MinPc = "" },
    @{ Name = "Update Virtual Machine Project";              MinPc = "" },
    @{ Name = "Customise Virtual Machine Guest";             MinPc = "" },
    @{ Name = "Assign Virtual Machine Owner";                MinPc = "" },
    @{ Name = "Power On Virtual Machine";                    MinPc = "all" },
    @{ Name = "Power Off Virtual Machine";                   MinPc = "" },
    @{ Name = "Power Cycle Virtual Machine";                 MinPc = "" },
    @{ Name = "Reset Virtual Machine";                       MinPc = "" },
    @{ Name = "ACPI Shutdown Virtual Machine";               MinPc = "" },
    @{ Name = "Guest Shutdown Virtual Machine";              MinPc = "" },
    @{ Name = "Create Virtual Machine Disk";                 MinPc = "all" },
    @{ Name = "Delete Virtual Machine Disk";                 MinPc = "all" },
    @{ Name = "Update Virtual Machine Disk";                 MinPc = "" },
    @{ Name = "Update Virtual Machine Disk List";            MinPc = "" },
    @{ Name = "View Virtual Machine Disk";                   MinPc = "all" },
    @{ Name = "Create Virtual Machine NIC";                  MinPc = "7.5" },
    @{ Name = "Update Virtual Machine NIC";                  MinPc = "7.5" },
    @{ Name = "Delete Virtual Machine NIC";                  MinPc = "" },
    @{ Name = "View Virtual Machine NIC";                    MinPc = "7.5" },
    @{ Name = "Assign Virtual Machine NIC IP";               MinPc = "" },
    @{ Name = "Release Virtual Machine NIC IP";              MinPc = "" },
    @{ Name = "Associate Virtual Machine Categories";        MinPc = "" },
    @{ Name = "Disassociate Virtual Machine Categories";     MinPc = "" },
    @{ Name = "Create Virtual Machine CD ROM";               MinPc = "" },
    @{ Name = "Delete Virtual Machine CD ROM";               MinPc = "" },
    @{ Name = "Eject Virtual Machine CD ROM";                MinPc = "" },
    @{ Name = "Insert Virtual Machine CD ROM";               MinPc = "" },
    @{ Name = "View Virtual Machine CD ROM";                 MinPc = "" },
    @{ Name = "Create Virtual Machine GPU";                  MinPc = "" },
    @{ Name = "Delete Virtual Machine GPU";                  MinPc = "" },
    @{ Name = "View Virtual Machine GPU";                    MinPc = "" },
    @{ Name = "Create Virtual Machine PCIe Device";          MinPc = "" },
    @{ Name = "Delete Virtual Machine PCIe Device";          MinPc = "" },
    @{ Name = "View Virtual Machine PCIe Device";            MinPc = "" },
    @{ Name = "Create Virtual Machine Serial Port";          MinPc = "" },
    @{ Name = "Delete Virtual Machine Serial Port";          MinPc = "" },
    @{ Name = "Update Virtual Machine Serial Port";          MinPc = "" },
    @{ Name = "View Virtual Machine Serial Port";            MinPc = "" },
    @{ Name = "View Virtual Machine Profile";                MinPc = "" },
    @{ Name = "Deploy Virtual Machine From VM Profile";      MinPc = "" },

    # --- Categories (v4 for PC 7.3/7.5+ AND legacy v3) ---
    @{ Name = "Create Category";                             MinPc = "7.3" },
    @{ Name = "Delete Category";                             MinPc = "7.3" },
    @{ Name = "Update Category";                             MinPc = "" },
    @{ Name = "View Category";                               MinPc = "7.3" },
    @{ Name = "Share Category";                              MinPc = "" },
    @{ Name = "Unshare Category";                            MinPc = "" },
    @{ Name = "Create Or Update Name Category";              MinPc = "" },
    @{ Name = "Create Or Update Value Category";             MinPc = "" },
    @{ Name = "Delete Name Category";                        MinPc = "" },
    @{ Name = "Delete Value Category";                       MinPc = "" },
    @{ Name = "View Name Category";                          MinPc = "" },
    @{ Name = "View Value Category";                         MinPc = "" },
    @{ Name = "Create Category Mapping";                     MinPc = "" },
    @{ Name = "Delete Category Mapping";                     MinPc = "" },
    @{ Name = "Update Category Mapping";                     MinPc = "" },
    @{ Name = "View Category Mapping";                       MinPc = "" },

    # --- Cluster, Host, GPU Profiles, Storage Container, Project, Resource Group, Image ---
    @{ Name = "View Cluster";                                MinPc = "all" },
    @{ Name = "View Host";                                   MinPc = "all" },
    @{ Name = "View Cluster Host";                           MinPc = "7.5" },
    @{ Name = "View Cluster Pgpu Profiles";                  MinPc = "" },
    @{ Name = "View Cluster Vgpu Profiles";                  MinPc = "" },
    @{ Name = "View Physical Gpu Profile";                   MinPc = "" },
    @{ Name = "View Virtual Gpu Profile";                    MinPc = "" },
    @{ Name = "View Cluster Storage Config";                 MinPc = "" },
    @{ Name = "View Disk";                                   MinPc = "" },
    @{ Name = "Get Cluster Network Segment";                 MinPc = "" },
    @{ Name = "View Container";                              MinPc = "" },
    @{ Name = "View Container Stats";                        MinPc = "" },
    @{ Name = "View Container Datastore";                    MinPc = "" },
    @{ Name = "View Storage Container";                      MinPc = "" },
    @{ Name = "View Storage Container Stats";                MinPc = "" },
    @{ Name = "View Storage Container Datastore";            MinPc = "" },
    @{ Name = "View Storage Policy";                         MinPc = "" },
    @{ Name = "View Project";                                MinPc = "all" },
    @{ Name = "View Resource Group";                         MinPc = "" },
    @{ Name = "View Resource Groups";                        MinPc = "" },
    @{ Name = "View Image";                                  MinPc = "all" },
    @{ Name = "Create Image";                                MinPc = "" },
    @{ Name = "Delete Image";                                MinPc = "" },
    @{ Name = "Update Image";                                MinPc = "" },
    @{ Name = "View Content Repository Item";                MinPc = "" },

    # --- Networking & IPAM ---
    @{ Name = "View Subnet";                                 MinPc = "all" },
    @{ Name = "View Overlay Subnet";                         MinPc = "" },
    @{ Name = "View External Subnet";                        MinPc = "" },
    @{ Name = "View Overlay External Subnet";                MinPc = "" },
    @{ Name = "View Remote Subnet";                          MinPc = "" },
    @{ Name = "View VPC";                                    MinPc = "" },
    @{ Name = "Reserve Subnet Ip";                           MinPc = "" },
    @{ Name = "Unreserve Subnet Ip";                         MinPc = "" },
    @{ Name = "View Subnet Reserved Ip";                     MinPc = "" },

    # --- Volume Groups & CSI 3.7 / 3.9 ---
    @{ Name = "Create Volume Group";                         MinPc = "" },
    @{ Name = "Delete Volume Group";                         MinPc = "" },
    @{ Name = "Update Volume Group";                         MinPc = "" },
    @{ Name = "Update Volume Group Details";                 MinPc = "" },
    @{ Name = "Revert Volume Group";                         MinPc = "" },
    @{ Name = "View Volume Group";                           MinPc = "" },
    @{ Name = "View Volume Group Details";                   MinPc = "" },
    @{ Name = "View Volume Group Metadata";                  MinPc = "" },
    @{ Name = "View Volume Group Stats";                     MinPc = "" },
    @{ Name = "Create Volume Group Disk";                    MinPc = "" },
    @{ Name = "Delete Volume Group Disk";                    MinPc = "" },
    @{ Name = "Update Volume Group Disk";                    MinPc = "" },
    @{ Name = "Update Volume Group Virtual Disks";           MinPc = "" },
    @{ Name = "View Volume Group Disks";                     MinPc = "" },
    @{ Name = "View Volume Group Disk Stats";                MinPc = "" },
    @{ Name = "Attach Volume Group To AHV VM";               MinPc = "" },
    @{ Name = "Detach Volume Group From AHV VM";             MinPc = "all" },
    @{ Name = "View Volume Group VM Attachments";            MinPc = "" },
    @{ Name = "Attach Volume Group To External ISCSI Client"; MinPc = "" },
    @{ Name = "Detach Volume Group From External ISCSI Client"; MinPc = "" },
    @{ Name = "Attach Volume Group To External NVMF Client"; MinPc = "" },
    @{ Name = "Detach Volume Group From External NVMF Client"; MinPc = "" },
    @{ Name = "View External ISCSI Client";                  MinPc = "" },
    @{ Name = "Update External ISCSI Client";                MinPc = "" },
    @{ Name = "View Volume Group ISCSI Attachments";         MinPc = "" },
    @{ Name = "Associate Volume Group Categories";           MinPc = "" },
    @{ Name = "Disassociate Volume Group Categories";        MinPc = "" },
    @{ Name = "Update Volume Group Categories";              MinPc = "" },
    @{ Name = "View Volume Group Category Associations";     MinPc = "" },

    # --- Data Protection / Recovery Points (CSI snapshots & clones) ---
    @{ Name = "Create Recovery Point";                       MinPc = "" },
    @{ Name = "Delete Recovery Point";                       MinPc = "" },
    @{ Name = "View Recovery Point";                         MinPc = "" },
    @{ Name = "Restore Recovery Point";                      MinPc = "" },
    @{ Name = "Replicate Recovery Point";                    MinPc = "" },
    @{ Name = "Set Expiration Time Recovery Point";          MinPc = "" },
    @{ Name = "Discover Cluster Recovery Point";             MinPc = "" },
    @{ Name = "View Data Protection Cluster Capabilities";   MinPc = "" },
    @{ Name = "View Recovery Point Store";                   MinPc = "" },
    @{ Name = "View Virtual Machine Recovery Point";         MinPc = "" },
    @{ Name = "Compute Changed Regions Virtual Machine Recovery Point"; MinPc = "" },
    @{ Name = "Compute Changed Regions Volume Group Recovery Point";    MinPc = "" },
    @{ Name = "Create AHV VM Recovery Point";                MinPc = "" },
    @{ Name = "Delete AHV VM Recovery Point";                MinPc = "" },
    @{ Name = "Restore AHV VM Recovery Point";               MinPc = "" },
    @{ Name = "View AHV VM Recovery Point";                  MinPc = "" },

    # --- Metro / Disaster Recovery (optional, used by CAPX NutanixMetro / vHA) ---
    @{ Name = "View Protection Policy";                      MinPc = "" },
    @{ Name = "Create Protection Policy";                    MinPc = "" },
    @{ Name = "Update Protection Policy";                    MinPc = "" },
    @{ Name = "Delete Protection Policy";                    MinPc = "" },
    @{ Name = "View Recovery Plan";                          MinPc = "" },
    @{ Name = "Create Recovery Plan";                        MinPc = "" },
    @{ Name = "Update Recovery Plan";                        MinPc = "" },
    @{ Name = "Delete Recovery Plan";                        MinPc = "" },
    @{ Name = "View Recovery Plan Config";                   MinPc = "" },
    @{ Name = "Create Recovery Plan Config";                 MinPc = "" },
    @{ Name = "Update Recovery Plan Config";                 MinPc = "" },
    @{ Name = "Delete Recovery Plan Config";                 MinPc = "" }
)

function ConvertTo-Norm([string]$Value) {
    return (($Value -replace '[_-]', ' ') -replace '\s+', ' ').Trim().ToLower()
}

function Test-IsAssignableOperation($Row) {
    if (-not $Row -or -not $Row.PSObject.Properties['operationType'] -or -not $Row.operationType) {
        return $true
    }
    $t = ([string]$Row.operationType).ToUpper()
    return ($t -eq "EXTERNAL")
}

function Format-PrismError($Body) {
    if ($null -eq $Body) { return "(empty response)" }
    if ($Body -is [string]) { return $Body }
    try {
        if ($Body.data -and $Body.data.error) {
            $msgs = @($Body.data.error | ForEach-Object {
                if ($_.message) { $_.message } elseif ($_.code) { $_.code }
            } | Where-Object { $_ })
            if ($msgs.Count) { return ($msgs -join "; ") }
        }
        if ($Body.messageList) {
            $msgs = @($Body.messageList | ForEach-Object { $_.message } | Where-Object { $_ })
            if ($msgs.Count) { return ($msgs -join "; ") }
        }
    } catch {}
    return ($Body | ConvertTo-Json -Compress -Depth 6)
}

function Get-PrismEtag($Result) {
    if ($Result.Headers) {
        foreach ($key in @("ETag", "Etag", "etag")) {
            $val = $Result.Headers[$key]
            if ($val) {
                if ($val -is [Array]) { return [string]$val[0] }
                return [string]$val
            }
        }
    }
    if ($Result.Body) {
        foreach ($node in @($Result.Body, $Result.Body.data)) {
            if ($node -and $node.PSObject.Properties['$reserved']) {
                $resv = $node.'$reserved'
                foreach ($key in @("ETag", "Etag", "etag")) {
                    if ($resv -and $resv.PSObject.Properties[$key] -and $resv.$key) {
                        return [string]$resv.$key
                    }
                }
            }
        }
    }
    return $null
}

function Invoke-Prism([string]$Method, [string]$Path, $Body, [string]$Etag, [string]$AuthPair) {
    $auth = if ($AuthPair) { $AuthPair } else { $pair }
    $requestId = [guid]::NewGuid().ToString()
    $maxAttempts = 3
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        if ($Method -eq "GET" -and $attempt -gt 1) {
            $requestId = [guid]::NewGuid().ToString()
        }
        $headers = @{
            Accept            = "application/json"
            "Ntnx-Request-Id" = $requestId
            Authorization     = "Basic $auth"
        }
        if ($Etag) {
            $ifMatch = $Etag.Trim()
            if ($PSVersionTable.PSVersion.Major -ge 6 -and $ifMatch -ne '*' -and -not ($ifMatch.StartsWith('"') -and $ifMatch.EndsWith('"')) -and -not $ifMatch.StartsWith('W/"')) {
                $ifMatch = '"' + $ifMatch + '"'
            }
            $headers["If-Match"] = $ifMatch
        }
        $params = @{
            Method  = $Method
            Uri     = "$base$Path"
            Headers = $headers
        }
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $params.SkipCertificateCheck = $true
        } else {
            $params.UseBasicParsing = $true
        }
        if ($null -ne $Body) {
            $params.ContentType = "application/json"
            $params.Body = ($Body | ConvertTo-Json -Depth 20 -Compress)
        }
        $result = $null
        try {
            $response = Invoke-WebRequest @params
            $parsed = $null
            if ($response.Content) { $parsed = $response.Content | ConvertFrom-Json }
            $result = @{ Status = [int]$response.StatusCode; Headers = $response.Headers; Body = $parsed }
        } catch {
            $resp = $_.Exception.Response
            if (-not $resp) {
                $msgs = @()
                $ex = $_.Exception
                while ($ex) {
                    if ($ex.Message) { $msgs += $ex.Message }
                    $ex = $ex.InnerException
                }
                throw ($msgs -join " -> ")
            }
            $text = $null
            if ($resp -is [Net.HttpWebResponse]) {
                $reader = New-Object IO.StreamReader($resp.GetResponseStream())
                try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
            } elseif ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                $text = $_.ErrorDetails.Message
            } elseif ($resp.Content) {
                $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            }
            $parsed = $null
            if ($text) { try { $parsed = $text | ConvertFrom-Json } catch { $parsed = $text } }
            $result = @{ Status = [int]$resp.StatusCode; Headers = @{}; Body = $parsed }
        }
        if ($result.Status -in 429, 502, 503, 504 -and $attempt -lt $maxAttempts) {
            Start-Sleep -Seconds $attempt
            continue
        }
        return $result
    }
}

function Detect-PcVersion([string]$Override) {
    if ($Override -and $Override.Trim().ToLower() -ne "auto") {
        return (Parse-PcVersion $Override)
    }
    if ($env:PRISM_PC_VERSION -and $env:PRISM_PC_VERSION.Trim().ToLower() -ne "auto") {
        return (Parse-PcVersion $env:PRISM_PC_VERSION)
    }
    try {
        $r = Invoke-Prism GET "/api/clustermgmt/v4.0/config/clusters?`$limit=50" $null $null $null
        if ($r.Status -eq 200 -and $r.Body -and $r.Body.data) {
            foreach ($c in @($r.Body.data)) {
                $funcs = @($c.config.clusterFunction)
                if ($funcs -contains "PRISM_CENTRAL" -and $c.config.buildInfo.version) {
                    return (Parse-PcVersion ([string]$c.config.buildInfo.version))
                }
            }
        }
    } catch {}
    try {
        $r = Invoke-Prism GET "/api/prism/v4.0/config/domain-managers?`$limit=10" $null $null $null
        if ($r.Status -eq 200 -and $r.Body -and $r.Body.data) {
            foreach ($dm in @($r.Body.data)) {
                if ($dm.config -and $dm.config.buildInfo -and $dm.config.buildInfo.version) {
                    return (Parse-PcVersion ([string]$dm.config.buildInfo.version))
                }
            }
        }
    } catch {}
    try {
        $r = Invoke-Prism POST "/api/nutanix/v3/clusters/list" @{ kind = "cluster"; length = 50 } $null $null
        if ($r.Status -eq 200 -and $r.Body -and $r.Body.entities) {
            foreach ($e in @($r.Body.entities)) {
                $svcs = @($e.status.resources.config.service_list)
                if ($svcs -contains "PRISM_CENTRAL" -and $e.status.resources.config.build.version) {
                    return (Parse-PcVersion ([string]$e.status.resources.config.build.version))
                }
            }
        }
    } catch {}
    return $null
}

function Resolve-IamVersion([string]$Preferred) {
    $candidates = @()
    if ($Preferred) { $candidates += $Preferred.Trim() }
    elseif ($env:PRISM_IAM_VERSION) { $candidates += $env:PRISM_IAM_VERSION.Trim() }
    foreach ($v in @("v4.0", "v4.1", "v4.1.b3", "v4.1.b2", "v4.1.b1", "v4.0.b1")) {
        if ($candidates -notcontains $v) { $candidates += $v }
    }
    $tried = @()
    foreach ($ver in $candidates) {
        $probe = Invoke-Prism GET "/api/iam/$ver/authz/operations?`$page=0&`$limit=1" $null $null $null
        if ($probe.Status -eq 200) {
            return $ver
        }
        if ($probe.Status -in 401, 403) {
            throw "Authentication/authorization failed ($($probe.Status)) on $base using IAM ${ver}: $(Format-PrismError $probe.Body)"
        }
        $tried += "${ver}($($probe.Status))"
        if ($probe.Status -notin 404, 405, 410, 501) {
            throw "Probing IAM $ver failed ($($probe.Status)): $(Format-PrismError $probe.Body)"
        }
    }
    $alpha = Invoke-Prism GET "/api/iam/v4.0.a1/authz/operations?`$page=0&`$limit=1" $null $null $null
    if ($alpha.Status -eq 200) {
        throw "Prism Central at $base only exposes IAM v4.0.a1, which does not support /authz/authorization-policies. Upgrade Prism Central (pc.2024.2+ / 7.x) or assign the role in the UI."
    }
    throw "No compatible Prism Central IAM v4 API found at $base (tried: $($tried -join ', '))."
}

function Get-Pages([string]$Path) {
    $page = 0
    $all = @()
    while ($true) {
        $join = "?"
        if ($Path.Contains("?")) { $join = "&" }
        $result = Invoke-Prism GET "$Path${join}`$page=$page&`$limit=100" $null $null $null
        if ($result.Status -ne 200) {
            throw "GET $Path failed ($($result.Status)): $(Format-PrismError $result.Body)"
        }
        $rows = @($result.Body.data)
        if ($rows.Count -eq 1 -and $null -eq $rows[0]) { $rows = @() }
        $all += $rows
        $total = $null
        if ($result.Body -and $result.Body.metadata) {
            $total = $result.Body.metadata.totalAvailableResults
        }
        $page++
        if ($rows.Count -eq 0) { return $all }
        if ($null -ne $total) {
            if ($all.Count -ge $total) { return $all }
        } elseif ($rows.Count -lt 100) {
            return $all
        }
    }
}

function Update-PrismResource([string]$UrlPath, [string]$Label, $Body) {
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $current = Invoke-Prism GET $UrlPath $null $null $null
        if ($current.Status -ne 200) {
            throw "GET $Label failed ($($current.Status)): $(Format-PrismError $current.Body)"
        }
        $etag = Get-PrismEtag $current
        if (-not $etag) {
            throw "GET $Label returned no ETag header or `$reserved.Etag; cannot send If-Match for PUT."
        }
        $updated = Invoke-Prism PUT $UrlPath $Body $etag $null
        if ($updated.Status -in 200, 202) {
            return $true
        }
        if ($updated.Status -eq 412 -and $attempt -lt 2) {
            continue
        }
        throw "update $Label failed ($($updated.Status)): $(Format-PrismError $updated.Body)"
    }
}

$iamVersion = Resolve-IamVersion $ApiVersion
$iamBase = "/api/iam/$iamVersion"
$pcVer = Detect-PcVersion $PcVersion
if ($pcVer) {
    Write-Host "Detected Prism Central version: $($pcVer.Raw) (IAM $iamVersion at $base)"
} else {
    Write-Host "Using Prism Central IAM $iamVersion at $base (PC version not reported; matching all available v3+v4 operations)"
}

Write-Host "Reading operations from $base ..."
$operations = @(Get-Pages "$iamBase/authz/operations")
$byName = @{}
$byId = @{}
foreach ($row in $operations) {
    if ($row.extId) { $byId[[string]$row.extId] = $row }
    if (-not (Test-IsAssignableOperation $row)) { continue }
    $labels = @()
    if ($row.PSObject.Properties['displayName'] -and $row.displayName) { $labels += [string]$row.displayName }
    if ($row.PSObject.Properties['name'] -and $row.name) { $labels += [string]$row.name }
    foreach ($label in $labels) {
        $normKey = ConvertTo-Norm $label
        if (-not $byName.ContainsKey($normKey)) { $byName[$normKey] = @() }
        if ($byName[$normKey] -notcontains $row) { $byName[$normKey] += $row }
    }
}

function Test-IsRequired([string]$MinPc, $PcVer) {
    if ($MinPc -eq "all") { return $true }
    if (-not $PcVer) { return $false }
    if ($MinPc -eq "7.3") { return [bool]$PcVer.IsPc73Plus }
    if ($MinPc -eq "7.5") { return [bool]$PcVer.IsPc75Plus }
    return $false
}

$selectedById = @{}
$directList = @()
$missingRequired = @()
$missingOptional = @()

foreach ($item in $permissions) {
    $key = ConvertTo-Norm $item.Name
    if ($byName.ContainsKey($key)) {
        foreach ($row in $byName[$key]) {
            $oid = [string]$row.extId
            if ($oid -and -not $selectedById.ContainsKey($oid)) {
                $selectedById[$oid] = $row
                $directList += $row
            }
        }
    } elseif (Test-IsRequired $item.MinPc $pcVer) {
        $missingRequired += $item.Name
    } else {
        $missingOptional += $item.Name
    }
}

# Ensure at least one equivalent operation matched for renamed operation groups
$requiredGroups = @(
    @{ Label = "Create Virtual Machine";   Alts = @("Create New Virtual Machine", "Create Virtual Machine") },
    @{ Label = "Delete Virtual Machine";   Alts = @("Delete Existing Virtual Machine", "Delete Virtual Machine") },
    @{ Label = "View Virtual Machine";     Alts = @("View Existing Virtual Machine", "View Virtual Machine") },
    @{ Label = "View Storage Container";   Alts = @("View Container", "View Storage Container") }
)
foreach ($grp in $requiredGroups) {
    $found = $false
    foreach ($alt in $grp.Alts) {
        if ($byName.ContainsKey((ConvertTo-Norm $alt))) { $found = $true; break }
    }
    if (-not $found -and ($missingRequired -notcontains $grp.Label)) {
        $missingRequired += $grp.Label
    }
}

# Recursively resolve predecessor / related operations (relatedOperationList) just like Prism Central UI does
$queue = New-Object System.Collections.Generic.Queue[object]
foreach ($row in $directList) { $queue.Enqueue($row) }
$resolvedRelated = @()
while ($queue.Count -gt 0) {
    $cur = $queue.Dequeue()
    if (-not $cur -or -not $cur.PSObject.Properties['relatedOperationList'] -or -not $cur.relatedOperationList) {
        continue
    }
    foreach ($relIdRaw in @($cur.relatedOperationList)) {
        $relId = [string]$relIdRaw
        if (-not $relId -or $selectedById.ContainsKey($relId)) { continue }
        $relRow = $null
        if ($byId.ContainsKey($relId)) {
            $relRow = $byId[$relId]
        } else {
            $fetched = Invoke-Prism GET "$iamBase/authz/operations/$relId" $null $null $null
            if ($fetched.Status -eq 200 -and $fetched.Body -and $fetched.Body.data) {
                $relRow = $fetched.Body.data
            }
        }
        if ($relRow) {
            if (-not (Test-IsAssignableOperation $relRow)) { continue }
            $selectedById[$relId] = $relRow
            $resolvedRelated += $relRow
            $queue.Enqueue($relRow)
        } else {
            $fallback = [pscustomobject]@{ extId = $relId; displayName = $relId }
            $selectedById[$relId] = $fallback
            $resolvedRelated += $fallback
        }
    }
}

Write-Host "matched $($directList.Count) direct permissions + $($resolvedRelated.Count) predecessor/related operations (total $($selectedById.Count) from $($operations.Count) PC operations)"
if ($missingOptional.Count) { Write-Host "not on this Prism Central (optional): $($missingOptional -join ', ')" }
if ($missingRequired.Count) { throw "missing required permissions: $($missingRequired -join ', ')" }

if ($PrintOnly) {
    Write-Host "--- Direct permissions ($($directList.Count)) ---"
    foreach ($row in $directList) {
        $label = if ($row.displayName) { $row.displayName } else { $row.name }
        Write-Host "  $label"
    }
    if ($resolvedRelated.Count) {
        Write-Host "--- Auto-resolved predecessor/related operations ($($resolvedRelated.Count)) ---"
        foreach ($row in $resolvedRelated) {
            $label = if ($row.displayName) { $row.displayName } else { $row.extId }
            Write-Host "  + $label"
        }
    }
    return
}

$operationIds = @($selectedById.Keys)
$roles = @(Get-Pages "$iamBase/authz/roles")
$role = $roles | Where-Object { $_.displayName -eq $roleName } | Select-Object -First 1
$pcTag = if ($pcVer) { "PC $($pcVer.Raw)" } else { "PC v4" }
# Note: Prism Central IAM v4 Role.description forbids ()+&%<>;"'`/\ characters
$roleDesc = "Permissions for NKP 2.19 CAPX, CCM, CAREN, IPAM, and CSI 3.9 on $pcTag with auto-resolved related operations."
$body = @{
    displayName = $roleName
    description = $roleDesc
    operations  = $operationIds
}
if (-not $role) {
    $created = Invoke-Prism POST "$iamBase/authz/roles" $body $null $null
    if ($created.Status -in 200, 201, 202) {
        $role = if ($created.Body.data) { $created.Body.data } else { $created.Body }
        Write-Host "created role $roleName ($($operationIds.Count) operations)"
    } elseif ($created.Status -eq 409) {
        $roles = @(Get-Pages "$iamBase/authz/roles")
        $role = $roles | Where-Object { $_.displayName -eq $roleName } | Select-Object -First 1
        if (-not $role) {
            throw "create role returned 409 conflict, but role $roleName was not found: $(Format-PrismError $created.Body)"
        }
        $null = Update-PrismResource "$iamBase/authz/roles/$($role.extId)" "role $roleName" $body
        Write-Host "updated role $roleName ($($operationIds.Count) operations, recovered from 409 conflict)"
    } else {
        throw "create role failed ($($created.Status)): $(Format-PrismError $created.Body)"
    }
} else {
    $null = Update-PrismResource "$iamBase/authz/roles/$($role.extId)" "role $roleName" $body
    Write-Host "updated role $roleName ($($operationIds.Count) operations)"
}

$pcUser = $null
$quotedUser = [Uri]::EscapeDataString($nkpUser.Replace("'", "''"))
$filtered = Invoke-Prism GET "$iamBase/authn/users?`$filter=username%20eq%20'$quotedUser'" $null $null $null
if ($filtered.Status -eq 200 -and $filtered.Body -and $filtered.Body.data) {
    $pcUser = @($filtered.Body.data) | Where-Object { $_.username -eq $nkpUser } | Select-Object -First 1
}
if (-not $pcUser) {
    $users = @(Get-Pages "$iamBase/authn/users")
    $pcUser = $users | Where-Object { $_.username -eq $nkpUser } | Select-Object -First 1
}
if (-not $pcUser) { throw "Prism Central user $nkpUser does not exist. Create the user first." }

$userType = if ($pcUser.PSObject.Properties['userType'] -and $pcUser.userType) { [string]$pcUser.userType } else { "unknown" }
$userStatus = if ($pcUser.PSObject.Properties['status'] -and $pcUser.status) { [string]$pcUser.status } else { "unknown" }
Write-Host "Target user: $nkpUser (type=$userType, status=$userStatus, extId=$($pcUser.extId))"
if ($userStatus -ne "unknown" -and $userStatus.ToUpper() -ne "ACTIVE") {
    Write-Warning "User $nkpUser status is $userStatus (expected ACTIVE)."
}

$policy = @{
    displayName             = $policyName
    description             = "Assign $roleName to $nkpUser for all entities."
    authorizationPolicyType = "USER_DEFINED"
    role                    = $role.extId
    identities              = @(@{ '$reserved' = @{ user = @{ uuid = @{ anyof = @($pcUser.extId) } } } })
    entities                = @(@{ '$reserved' = @{ '*' = @{ '*' = @{ eq = '*' } } } })
}

$policies = @(Get-Pages "$iamBase/authz/authorization-policies")
$existingPolicy = $policies | Where-Object { $_.displayName -eq $policyName } | Select-Object -First 1
if ($existingPolicy) {
    $null = Update-PrismResource "$iamBase/authz/authorization-policies/$($existingPolicy.extId)" "policy $policyName" $policy
    Write-Host "updated policy $policyName (role=$roleName, user=$nkpUser, scope=all entities)"
} else {
    $made = Invoke-Prism POST "$iamBase/authz/authorization-policies" $policy $null $null
    if ($made.Status -in 200, 201, 202) {
        Write-Host "assigned $roleName to $nkpUser (policy=$policyName, scope=all entities)"
    } elseif ($made.Status -eq 409) {
        $policies = @(Get-Pages "$iamBase/authz/authorization-policies")
        $existingPolicy = $policies | Where-Object { $_.displayName -eq $policyName } | Select-Object -First 1
        if ($existingPolicy) {
            $null = Update-PrismResource "$iamBase/authz/authorization-policies/$($existingPolicy.extId)" "policy $policyName" $policy
            Write-Host "updated policy $policyName (recovered from 409 conflict)"
        } else {
            Write-Host "policy $policyName already exists (409)"
        }
    } else {
        throw "create policy failed ($($made.Status)): $(Format-PrismError $made.Body)"
    }
}

if ($nkpAuthPair) {
    Write-Host ""
    Write-Host "Verifying NKP API access as $nkpUser ..."
    $checks = @(
        @{ Label = "CAREN ValidateCredentials (View User)";          Path = "$iamBase/authn/users?`$limit=1" },
        @{ Label = "CAREN/CAPX/CCM Version (View Domain Manager)";   Path = "/api/prism/v4.0/config/domain-managers" },
        @{ Label = "Clusters (View Cluster)";                        Path = "/api/clustermgmt/v4.0/config/clusters?`$limit=1" },
        @{ Label = "Storage Containers (View Container)";            Path = "/api/clustermgmt/v4.0/config/storage-containers?`$limit=1" },
        @{ Label = "Images (View Image)";                            Path = "/api/vmm/v4.0/content/images?`$limit=1" },
        @{ Label = "Subnets (View Subnet)";                          Path = "/api/networking/v4.0/config/subnets?`$limit=1" },
        @{ Label = "AHV VMs (View Existing Virtual Machine)";        Path = "/api/vmm/v4.0/ahv/config/vms?`$limit=1" },
        @{ Label = "Categories (View Category)";                     Path = "/api/prism/v4.0/config/categories?`$limit=1" }
    )
    $failedChecks = 0
    foreach ($chk in $checks) {
        $res = Invoke-Prism GET $chk.Path $null $null $nkpAuthPair
        if ($res.Status -eq 200) {
            Write-Host "  [PASS 200] $($chk.Label)"
        } else {
            $failedChecks++
            Write-Warning "  [FAIL $($res.Status)] $($chk.Label) -> $(Format-PrismError $res.Body)"
        }
    }
    if ($failedChecks -gt 0) {
        throw "Verification failed for $failedChecks NKP API check(s) as $nkpUser."
    }
    Write-Host "All $($checks.Count) NKP API permission checks passed as $nkpUser."
}
