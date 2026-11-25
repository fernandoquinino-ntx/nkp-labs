# Ask for the Prism Central IP, the role name, and the NKP user, then create
# that role and assign it. The user must already exist. The admin password is
# not printed and is not saved.
#
#   powershell -ExecutionPolicy Bypass -File .\create-prism-role.ps1
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

function Read-Required([string]$Prompt, [string]$Default) {
    $suffix = ""
    if ($Default) { $suffix = " [$Default]" }
    $value = Read-Host "$Prompt$suffix"
    if (-not $value) { $value = $Default }
    if (-not $value) { throw "$Prompt is required" }
    return $value.Trim()
}

Write-Host "Prism Central role for nkp create cluster"
$ip = Read-Required "Prism Central IP"
$roleName = Read-Required "Role name" "NKP Cluster Create"
$nkpUser = Read-Required "NKP user (must already exist in Prism Central)"
$admin = Read-Required "Prism Central admin user" "admin"
$secure = Read-Host "Prism Central admin password" -AsSecureString
$ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try { $adminPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
$policyName = "$roleName policy"
$base = "https://${ip}:9440"
$pair = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${admin}:${adminPassword}"))
$adminPassword = $null

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

function Invoke-Prism([string]$Method, [string]$Path, $Body, [string]$Etag) {
    $headers = @{
        Accept           = "application/json"
        "Ntnx-Request-Id" = [guid]::NewGuid().ToString()
        Authorization    = "Basic $pair"
    }
    if ($Etag) { $headers["If-Match"] = $Etag }
    $params = @{
        Method      = $Method
        Uri         = "$base$Path"
        Headers     = $headers
        ContentType = "application/json"
    }
    if ($null -ne $Body) { $params.Body = ($Body | ConvertTo-Json -Depth 20 -Compress) }
    try {
        $response = Invoke-WebRequest @params -UseBasicParsing
        $parsed = $null
        if ($response.Content) { $parsed = $response.Content | ConvertFrom-Json }
        return @{ Status = [int]$response.StatusCode; Headers = $response.Headers; Body = $parsed }
    } catch {
        $resp = $_.Exception.Response
        if (-not $resp) { throw }
        $reader = New-Object IO.StreamReader($resp.GetResponseStream())
        $text = $reader.ReadToEnd()
        $parsed = $null
        if ($text) { try { $parsed = $text | ConvertFrom-Json } catch { $parsed = $text } }
        return @{ Status = [int]$resp.StatusCode; Headers = @{}; Body = $parsed }
    }
}

function Get-Pages([string]$Path) {
    $page = 0
    $all = @()
    while ($true) {
        $join = "?"
        if ($Path.Contains("?")) { $join = "&" }
        $result = Invoke-Prism GET "$Path${join}`$page=$page&`$limit=100" $null $null
        if ($result.Status -ne 200) {
            throw "GET $Path failed ($($result.Status)): $($result.Body | ConvertTo-Json -Compress -Depth 6)"
        }
        $rows = @($result.Body.data)
        if ($rows.Count -eq 1 -and $null -eq $rows[0]) { $rows = @() }
        $all += $rows
        $total = $result.Body.metadata.totalAvailableResults
        $page++
        if ($rows.Count -eq 0 -or $rows.Count -lt 100 -or ($null -ne $total -and ($page * 100) -ge $total)) {
            return $all
        }
    }
}

Write-Host "Reading operations from $ip ..."
$operations = @(Get-Pages "/api/iam/v4.0/authz/operations")
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

$operationIds = @($chosen | ForEach-Object { $_.extId })
$roles = @(Get-Pages "/api/iam/v4.0/authz/roles")
$role = $roles | Where-Object { $_.displayName -eq $roleName } | Select-Object -First 1
$body = @{
    displayName = $roleName
    description = "Permissions for nkp create cluster. NKP 2.19 Prism Central role plus CAPX VM and category operations."
    operations  = $operationIds
}
if (-not $role) {
    $created = Invoke-Prism POST "/api/iam/v4.0/authz/roles" $body $null
    if ($created.Status -notin 200, 201, 202) {
        throw "create role failed ($($created.Status)): $($created.Body | ConvertTo-Json -Compress -Depth 6)"
    }
    $role = $created.Body.data
    Write-Host "created role $roleName"
} else {
    $current = Invoke-Prism GET "/api/iam/v4.0/authz/roles/$($role.extId)" $null $null
    $etag = $current.Headers["ETag"]
    if (-not $etag) { $etag = $current.Headers["Etag"] }
    $updated = Invoke-Prism PUT "/api/iam/v4.0/authz/roles/$($role.extId)" $body $etag
    if ($updated.Status -notin 200, 202) {
        throw "update role failed ($($updated.Status)): $($updated.Body | ConvertTo-Json -Compress -Depth 6)"
    }
    Write-Host "updated role $roleName"
}

$users = @(Get-Pages "/api/iam/v4.0/authn/users")
$pcUser = $users | Where-Object { $_.username -eq $nkpUser } | Select-Object -First 1
if (-not $pcUser) { throw "Prism Central user $nkpUser does not exist. Create the user first." }

$policies = @(Get-Pages "/api/iam/v4.0/authz/authorization-policies")
if ($policies | Where-Object { $_.displayName -eq $policyName }) {
    Write-Host "policy $policyName already exists"
    return
}
$policy = @{
    displayName = $policyName
    description = "Assign $roleName to $nkpUser for all entities."
    role        = $role.extId
    identities  = @(@{ '$reserved' = @{ user = @{ uuid = @{ anyof = @($pcUser.extId) } } } })
    entities    = @(@{ '$reserved' = @{ '*' = @{ '*' = @{ eq = '*' } } } })
}
$made = Invoke-Prism POST "/api/iam/v4.0/authz/authorization-policies" $policy $null
if ($made.Status -notin 200, 201, 202) {
    throw "create policy failed ($($made.Status)): $($made.Body | ConvertTo-Json -Compress -Depth 8)"
}
Write-Host "assigned $roleName to $nkpUser"
