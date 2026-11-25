# Ask for the Prism Central IP, the role name, and the NKP user, then create
# (or update) that role with the full NKP 2.19 + CAPX + CSI 3.9 permissions
# (including PC 7.3/7.5+ v4 operations and recursive relatedOperationList
# predecessor resolution) and assign it. The user must already exist.
# The admin password is not printed and is not saved.
#
#   powershell -ExecutionPolicy Bypass -File .\create-prism-role.ps1
#
# Optional non-interactive parameters (prompted when omitted):
#   -PrismIp <ip-or-url> -RoleName <name> -NkpUser <user>
#   -AdminUser <admin> -AdminPassword <pass> -PcVersion <auto|7.5|7.3|2024.3>
#   -ApiVersion <v4.0|v4.1.b3|...> -PrintOnly
#Requires -Version 5.1
param(
    [string]$PrismIp,
    [string]$RoleName,
    [string]$NkpUser,
    [string]$AdminUser,
    [string]$AdminPassword,
    [string]$PcVersion,
    [string]$ApiVersion,
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
        return @{ Raw = $clean; Major = $maj; Minor = $min; Patch = $pat; IsPc73Plus = ($maj -ge 7 -and $maj -lt 2000 -and ($maj -gt 7 -or $min -ge 3)); IsPc75Plus = ($maj -ge 7 -and $maj -lt 2000 -and ($maj -gt 7 -or $min -ge 5)) }
    }
    return $null
}

Write-Host "Prism Central role for NKP 2.19 (CAPX + CCM + CSI)"
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

# Permission matrix covering NKP 2.19 + CAPX v1.9/v1.10 + CCM + Nutanix CSI 3.7/3.9
# across PC 2024.x, pc.7.3, pc.7.5, and pc.7.6+.
# Unlike alias-only matching, EVERY listed operation name that exists on this Prism Central
# is added (both legacy v3 and v4 operation names), and relatedOperationList predecessors
# are resolved recursively below.
# MinPc: "" = always optional, "all" = always required, "7.3" = required on PC 7.3+, "7.5" = required on PC 7.5+
$permissions = @(
    # --- AHV VM (v4 + legacy v3) ---
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
    @{ Name = "View Virtual Machine NIC";                    MinPc = "" },
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

    # --- Categories (v4 for PC 7.3/7.5+ AND legacy v3) ---
    @{ Name = "Create Category";                             MinPc = "7.3" },
    @{ Name = "Delete Category";                             MinPc = "7.3" },
    @{ Name = "Update Category";                             MinPc = "" },
    @{ Name = "View Category";                               MinPc = "7.3" },
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

    # --- Tasks & Prism Central ---
    @{ Name = "View Task";                                   MinPc = "" },
    @{ Name = "Fetch Task Response";                         MinPc = "" },
    @{ Name = "View Prism Central";                          MinPc = "" },

    # --- Cluster, Host, Image, Project, Storage Container ---
    @{ Name = "View Cluster";                                MinPc = "all" },
    @{ Name = "View Host";                                   MinPc = "all" },
    @{ Name = "View Cluster Host";                           MinPc = "" },
    @{ Name = "View Cluster Pgpu Profiles";                  MinPc = "" },
    @{ Name = "View Cluster Vgpu Profiles";                  MinPc = "" },
    @{ Name = "Get Cluster Network Segment";                 MinPc = "" },
    @{ Name = "View Storage Container";                      MinPc = "" },
    @{ Name = "View Project";                                MinPc = "all" },
    @{ Name = "View Resource Groups";                        MinPc = "" },
    @{ Name = "View Image";                                  MinPc = "all" },
    @{ Name = "Create Image";                                MinPc = "" },
    @{ Name = "Delete Image";                                MinPc = "" },
    @{ Name = "Update Image";                                MinPc = "" },

    # --- Networking ---
    @{ Name = "View Subnet";                                 MinPc = "all" },
    @{ Name = "View Overlay Subnet";                         MinPc = "" },
    @{ Name = "View VPC";                                    MinPc = "" },
    @{ Name = "Reserve Subnet Ip";                           MinPc = "" },
    @{ Name = "Unreserve Subnet Ip";                         MinPc = "" },
    @{ Name = "View Subnet Reserved Ip";                     MinPc = "" },

    # --- Volume Groups & CSI 3.7 / 3.9 ---
    @{ Name = "Create Volume Group";                         MinPc = "" },
    @{ Name = "Delete Volume Group";                         MinPc = "" },
    @{ Name = "Update Volume Group";                         MinPc = "" },
    @{ Name = "Update Volume Group Details";                 MinPc = "" },
    @{ Name = "View Volume Group";                           MinPc = "" },
    @{ Name = "View Volume Group Details";                   MinPc = "" },
    @{ Name = "View Volume Group Metadata";                  MinPc = "" },
    @{ Name = "Create Volume Group Disk";                    MinPc = "" },
    @{ Name = "Delete Volume Group Disk";                    MinPc = "" },
    @{ Name = "Update Volume Group Disk";                    MinPc = "" },
    @{ Name = "Update Volume Group Virtual Disks";           MinPc = "" },
    @{ Name = "View Volume Group Disks";                     MinPc = "" },
    @{ Name = "Attach Volume Group To AHV VM";               MinPc = "" },
    @{ Name = "Detach Volume Group From AHV VM";             MinPc = "all" },
    @{ Name = "View Volume Group VM Attachments";            MinPc = "" },
    @{ Name = "Attach Volume Group To External ISCSI Client"; MinPc = "" },
    @{ Name = "Detach Volume Group From External ISCSI Client"; MinPc = "" },
    @{ Name = "View External ISCSI Client";                  MinPc = "" },
    @{ Name = "Update External ISCSI Client";                MinPc = "" },
    @{ Name = "View Volume Group ISCSI Attachments";         MinPc = "" },
    @{ Name = "Associate Volume Group Categories";           MinPc = "" },
    @{ Name = "Disassociate Volume Group Categories";        MinPc = "" },
    @{ Name = "Update Volume Group Categories";              MinPc = "" },
    @{ Name = "View Volume Group Category Associations";     MinPc = "" },
    @{ Name = "Create Recovery Point";                       MinPc = "" },
    @{ Name = "Delete Recovery Point";                       MinPc = "" },
    @{ Name = "View Recovery Point";                         MinPc = "" },
    @{ Name = "Restore Recovery Point";                      MinPc = "" }
)

function ConvertTo-Norm([string]$Value) {
    return (($Value -replace '[_-]', ' ') -replace '\s+', ' ').Trim().ToLower()
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

function Invoke-Prism([string]$Method, [string]$Path, $Body, [string]$Etag) {
    $requestId = [guid]::NewGuid().ToString()
    $maxAttempts = 3
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        if ($Method -eq "GET" -and $attempt -gt 1) {
            $requestId = [guid]::NewGuid().ToString()
        }
        $headers = @{
            Accept            = "application/json"
            "Ntnx-Request-Id" = $requestId
            Authorization     = "Basic $pair"
        }
        if ($Etag) { $headers["If-Match"] = $Etag }
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
        $r = Invoke-Prism GET "/api/clustermgmt/v4.0/config/clusters?`$limit=50" $null $null
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
        $r = Invoke-Prism GET "/api/prism/v4.0/config/domain-managers?`$limit=10" $null $null
        if ($r.Status -eq 200 -and $r.Body -and $r.Body.data) {
            foreach ($dm in @($r.Body.data)) {
                if ($dm.config -and $dm.config.buildInfo -and $dm.config.buildInfo.version) {
                    return (Parse-PcVersion ([string]$dm.config.buildInfo.version))
                }
            }
        }
    } catch {}
    try {
        $r = Invoke-Prism POST "/api/nutanix/v3/clusters/list" @{ kind = "cluster"; length = 50 } $null
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
        $probe = Invoke-Prism GET "/api/iam/$ver/authz/operations?`$page=0&`$limit=1" $null $null
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
    $alpha = Invoke-Prism GET "/api/iam/v4.0.a1/authz/operations?`$page=0&`$limit=1" $null $null
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
        $result = Invoke-Prism GET "$Path${join}`$page=$page&`$limit=100" $null $null
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
        if ($rows.Count -eq 0 -or $rows.Count -lt 100 -or ($null -ne $total -and ($page * 100) -ge $total)) {
            return $all
        }
    }
}

function Update-PrismRole([string]$IamBase, [string]$RoleId, $Body) {
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $current = Invoke-Prism GET "$IamBase/authz/roles/$RoleId" $null $null
        if ($current.Status -ne 200) {
            throw "GET role $RoleId failed ($($current.Status)): $(Format-PrismError $current.Body)"
        }
        $etag = Get-PrismEtag $current
        if (-not $etag) {
            throw "GET role $RoleId returned no ETag header or `$reserved.Etag; cannot send If-Match for PUT."
        }
        $updated = Invoke-Prism PUT "$IamBase/authz/roles/$RoleId" $Body $etag
        if ($updated.Status -in 200, 202) {
            return $true
        }
        if ($updated.Status -eq 412 -and $attempt -lt 2) {
            continue
        }
        throw "update role failed ($($updated.Status)): $(Format-PrismError $updated.Body)"
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
    $label = $row.displayName
    if (-not $label) { $label = $row.name }
    if ($label) {
        $normKey = ConvertTo-Norm $label
        if (-not $byName.ContainsKey($normKey)) { $byName[$normKey] = @() }
        $byName[$normKey] += $row
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

# Ensure at least one VM create/delete/view operation matched even if PC version could not be detected
$hasVmCreate = ($byName.ContainsKey((ConvertTo-Norm "Create New Virtual Machine")) -or $byName.ContainsKey((ConvertTo-Norm "Create Virtual Machine")))
$hasVmDelete = ($byName.ContainsKey((ConvertTo-Norm "Delete Existing Virtual Machine")) -or $byName.ContainsKey((ConvertTo-Norm "Delete Virtual Machine")))
$hasVmView   = ($byName.ContainsKey((ConvertTo-Norm "View Existing Virtual Machine")) -or $byName.ContainsKey((ConvertTo-Norm "View Virtual Machine")))
if (-not $hasVmCreate -and ($missingRequired -notcontains "Create Virtual Machine")) { $missingRequired += "Create Virtual Machine" }
if (-not $hasVmDelete -and ($missingRequired -notcontains "Delete Virtual Machine")) { $missingRequired += "Delete Virtual Machine" }
if (-not $hasVmView   -and ($missingRequired -notcontains "View Virtual Machine"))   { $missingRequired += "View Virtual Machine" }

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
        if ($byId.ContainsKey($relId)) {
            $relRow = $byId[$relId]
            $selectedById[$relId] = $relRow
            $resolvedRelated += $relRow
            $queue.Enqueue($relRow)
        } else {
            # Fallback: fetch operation by extId if it was omitted from list pagination
            $fetched = Invoke-Prism GET "$iamBase/authz/operations/$relId" $null $null
            if ($fetched.Status -eq 200 -and $fetched.Body -and $fetched.Body.data) {
                $relRow = $fetched.Body.data
                $selectedById[$relId] = $relRow
                $resolvedRelated += $relRow
                $queue.Enqueue($relRow)
            } else {
                $selectedById[$relId] = [pscustomobject]@{ extId = $relId; displayName = $relId }
                $resolvedRelated += $selectedById[$relId]
            }
        }
    }
}

Write-Host "matched $($directList.Count) direct permissions + $($resolvedRelated.Count) predecessor/related operations (total $($selectedById.Count))"
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
$body = @{
    displayName = $roleName
    description = "Permissions for NKP 2.19 (CAPX + CCM + CSI 3.9, $pcTag) with auto-resolved related operations."
    operations  = $operationIds
}
if (-not $role) {
    $created = Invoke-Prism POST "$iamBase/authz/roles" $body $null
    if ($created.Status -in 200, 201, 202) {
        $role = if ($created.Body.data) { $created.Body.data } else { $created.Body }
        Write-Host "created role $roleName ($($operationIds.Count) operations)"
    } elseif ($created.Status -eq 409) {
        $roles = @(Get-Pages "$iamBase/authz/roles")
        $role = $roles | Where-Object { $_.displayName -eq $roleName } | Select-Object -First 1
        if (-not $role) {
            throw "create role returned 409 conflict, but role $roleName was not found: $(Format-PrismError $created.Body)"
        }
        $null = Update-PrismRole $iamBase $role.extId $body
        Write-Host "updated role $roleName ($($operationIds.Count) operations, recovered from 409 conflict)"
    } else {
        throw "create role failed ($($created.Status)): $(Format-PrismError $created.Body)"
    }
} else {
    $null = Update-PrismRole $iamBase $role.extId $body
    Write-Host "updated role $roleName ($($operationIds.Count) operations)"
}

$pcUser = $null
$quotedUser = [Uri]::EscapeDataString($nkpUser.Replace("'", "''"))
$filtered = Invoke-Prism GET "$iamBase/authn/users?`$filter=username%20eq%20'$quotedUser'" $null $null
if ($filtered.Status -eq 200 -and $filtered.Body -and $filtered.Body.data) {
    $pcUser = @($filtered.Body.data) | Where-Object { $_.username -eq $nkpUser } | Select-Object -First 1
}
if (-not $pcUser) {
    $users = @(Get-Pages "$iamBase/authn/users")
    $pcUser = $users | Where-Object { $_.username -eq $nkpUser } | Select-Object -First 1
}
if (-not $pcUser) { throw "Prism Central user $nkpUser does not exist. Create the user first." }

$policies = @(Get-Pages "$iamBase/authz/authorization-policies")
$existingPolicy = $policies | Where-Object { $_.displayName -eq $policyName } | Select-Object -First 1
if ($existingPolicy) {
    if ($existingPolicy.role -and $existingPolicy.role -ne $role.extId) {
        Write-Warning "policy $policyName already exists but points to role $($existingPolicy.role) instead of $($role.extId)"
    } else {
        Write-Host "policy $policyName already exists"
    }
    return
}
$policy = @{
    displayName             = $policyName
    description             = "Assign $roleName to $nkpUser for all entities."
    authorizationPolicyType = "USER_DEFINED"
    role                    = $role.extId
    identities              = @(@{ '$reserved' = @{ user = @{ uuid = @{ anyof = @($pcUser.extId) } } } })
    entities                = @(@{ '$reserved' = @{ '*' = @{ '*' = @{ eq = '*' } } } })
}
$made = Invoke-Prism POST "$iamBase/authz/authorization-policies" $policy $null
if ($made.Status -in 200, 201, 202) {
    Write-Host "assigned $roleName to $nkpUser"
} elseif ($made.Status -eq 409) {
    Write-Host "policy $policyName already exists (409)"
} else {
    throw "create policy failed ($($made.Status)): $(Format-PrismError $made.Body)"
}
