# Ask for the Prism Central IP, the role name, and the NKP user, then create
# that role and assign it. The user must already exist. The admin password is
# not printed and is not saved.
#
#   powershell -ExecutionPolicy Bypass -File .\create-prism-role.ps1
#
# Optional non-interactive parameters (prompted when omitted):
#   -PrismIp <ip-or-url> -RoleName <name> -NkpUser <user>
#   -AdminUser <admin> -AdminPassword <pass> -ApiVersion <v4.0|v4.1.b3|...> -PrintOnly
#Requires -Version 5.1
param(
    [string]$PrismIp,
    [string]$RoleName,
    [string]$NkpUser,
    [string]$AdminUser,
    [string]$AdminPassword,
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

Write-Host "Prism Central role for nkp create cluster"
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

$permissions = @(
    @{ Names = @("Create Virtual Machine", "Create New Virtual Machine"); Required = $true },
    @{ Names = @("Delete Virtual Machine"); Required = $true },
    @{ Names = @("View Virtual Machine"); Required = $true },
    @{ Names = @("View Virtual Machine Disk"); Required = $true },
    @{ Names = @("Update Virtual Machine"); Required = $true },
    @{ Names = @("Power On Virtual Machine"); Required = $true },
    @{ Names = @("Create Virtual Machine Disk"); Required = $true },
    @{ Names = @("Delete Virtual Machine Disk"); Required = $true },
    @{ Names = @("Create Or Update Name Category"); Required = $true },
    @{ Names = @("Create Or Update Value Category"); Required = $true },
    @{ Names = @("Delete Name Category"); Required = $true },
    @{ Names = @("Delete Value Category"); Required = $true },
    @{ Names = @("View Name Category"); Required = $true },
    @{ Names = @("View Value Category"); Required = $true },
    @{ Names = @("Create Category Mapping"); Required = $true },
    @{ Names = @("Delete Category Mapping"); Required = $true },
    @{ Names = @("Update Category Mapping"); Required = $true },
    @{ Names = @("View Category Mapping"); Required = $true },
    @{ Names = @("View Cluster"); Required = $true },
    @{ Names = @("View Host"); Required = $true },
    @{ Names = @("View Image"); Required = $true },
    @{ Names = @("View Prism Central"); Required = $true },
    @{ Names = @("View Project"); Required = $true },
    @{ Names = @("View Subnet"); Required = $true },
    @{ Names = @("Detach Volume Group From AHV VM"); Required = $true },
    @{ Names = @("View VPC"); Required = $false },
    @{ Names = @("View Overlay Subnet"); Required = $false },
    @{ Names = @("View Cluster Pgpu Profiles"); Required = $false },
    @{ Names = @("View Cluster Vgpu Profiles"); Required = $false },
    @{ Names = @("Update Virtual Machine Custom Attributes"); Required = $false },
    @{ Names = @("Create Image"); Required = $false },
    @{ Names = @("Delete Image"); Required = $false },
    @{ Names = @("Create Volume Group"); Required = $false },
    @{ Names = @("View Volume Group"); Required = $false },
    @{ Names = @("Delete Volume Group"); Required = $false },
    @{ Names = @("Update Volume Group"); Required = $false },
    @{ Names = @("Attach Volume Group To AHV VM"); Required = $false },
    @{ Names = @("View Storage Container"); Required = $false }
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
Write-Host "Using Prism Central IAM $iamVersion at $base"
Write-Host "Reading operations from $base ..."
$operations = @(Get-Pages "$iamBase/authz/operations")
$byName = @{}
foreach ($row in $operations) {
    $label = $row.displayName
    if (-not $label) { $label = $row.name }
    if ($label) { $byName[(ConvertTo-Norm $label)] = $row }
}
$chosen = @()
$missingRequired = @()
$missingOptional = @()
foreach ($item in $permissions) {
    $match = $null
    foreach ($name in $item.Names) {
        $key = ConvertTo-Norm $name
        if ($byName.ContainsKey($key)) { $match = $byName[$key]; break }
    }
    if ($match) { $chosen += $match }
    elseif ($item.Required) { $missingRequired += $item.Names[0] }
    else { $missingOptional += $item.Names[0] }
}
Write-Host "matched $($chosen.Count) permissions"
if ($missingOptional.Count) { Write-Host "not on this Prism Central (optional): $($missingOptional -join ', ')" }
if ($missingRequired.Count) { throw "missing required permissions: $($missingRequired -join ', ')" }
if ($PrintOnly) {
    foreach ($row in $chosen) {
        $label = if ($row.displayName) { $row.displayName } else { $row.name }
        Write-Host "  $label"
    }
    return
}

$operationIds = @($chosen | ForEach-Object { $_.extId })
$roles = @(Get-Pages "$iamBase/authz/roles")
$role = $roles | Where-Object { $_.displayName -eq $roleName } | Select-Object -First 1
$body = @{
    displayName = $roleName
    description = "Permissions for nkp create cluster. NKP 2.19 Prism Central role plus CAPX VM and category operations."
    operations  = $operationIds
}
if (-not $role) {
    $created = Invoke-Prism POST "$iamBase/authz/roles" $body $null
    if ($created.Status -in 200, 201, 202) {
        $role = if ($created.Body.data) { $created.Body.data } else { $created.Body }
        Write-Host "created role $roleName"
    } elseif ($created.Status -eq 409) {
        $roles = @(Get-Pages "$iamBase/authz/roles")
        $role = $roles | Where-Object { $_.displayName -eq $roleName } | Select-Object -First 1
        if (-not $role) {
            throw "create role returned 409 conflict, but role $roleName was not found: $(Format-PrismError $created.Body)"
        }
        $null = Update-PrismRole $iamBase $role.extId $body
        Write-Host "updated role $roleName (recovered from 409 conflict)"
    } else {
        throw "create role failed ($($created.Status)): $(Format-PrismError $created.Body)"
    }
} else {
    $null = Update-PrismRole $iamBase $role.extId $body
    Write-Host "updated role $roleName"
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
