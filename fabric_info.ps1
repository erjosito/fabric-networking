<#
.SYNOPSIS
    Retrieves information about the Fabric environment and its networking configuration.

.DESCRIPTION
    Uses the Fabric REST API and Azure Resource Manager to display:
      - Fabric tenant settings related to networking / private links
      - Workspaces with their IDs, capacity assignments, and access policies
      - Tenant-level Private Link Services (Microsoft.PowerBI/privateLinkServicesForPowerBI)
      - Workspace-level Private Link Services (Microsoft.Fabric/privateLinkServicesForFabric)
      - Private Endpoints targeting those services
      - Fabric capacities and their state

.PARAMETER ResourceGroup
    Resource group to scan for Private Link resources. Default: fabricnetworking

.PARAMETER DebugApi
    Print all REST API requests and responses to the console.

.EXAMPLE
    .\fabric_info.ps1
    .\fabric_info.ps1 -DebugApi
    .\fabric_info.ps1 -ResourceGroup "my-rg"
#>

[CmdletBinding()]
param(
    [string]$ResourceGroup = 'fabricnetworking',
    [switch]$DebugApi
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Helpers ──────────────────────────────────────────────────────────────────────

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "  ┌──────────────────────────────────────────────────────────────" -ForegroundColor White
    Write-Host "  │ $Title" -ForegroundColor White
    Write-Host "  └──────────────────────────────────────────────────────────────" -ForegroundColor White
}

function Write-Item   { param([string]$Msg) Write-Host "     • $Msg" -ForegroundColor Gray }
function Write-OK     { param([string]$Msg) Write-Host "     ✅ $Msg" -ForegroundColor Green }
function Write-WarnMsg { param([string]$Msg) Write-Host "     ⚠️  $Msg" -ForegroundColor Yellow }
function Write-None   { param([string]$Msg) Write-Host "     — $Msg" -ForegroundColor DarkGray }

function Invoke-FabricApi {
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [string]$Method = 'Get',
        [string]$Body
    )
    if ($DebugApi) {
        Write-Host ""
        Write-Host "  ┌─ REST API Call ─────────────────────────────" -ForegroundColor DarkYellow
        Write-Host "  │ $Method $Uri" -ForegroundColor DarkYellow
        if ($Body) { Write-Host "  │ Body: $Body" -ForegroundColor DarkYellow }
        Write-Host "  └─────────────────────────────────────────────" -ForegroundColor DarkYellow
    }
    $params = @{ Uri = $Uri; Headers = $Headers; Method = $Method }
    if ($Body) { $params.Body = $Body; $params.ContentType = 'application/json' }
    $result = Invoke-RestMethod @params
    if ($DebugApi) {
        $json = $result | ConvertTo-Json -Depth 5 -Compress
        if ($json.Length -gt 2000) { $json = $json.Substring(0, 2000) + '... (truncated)' }
        Write-Host "  ┌─ Response ──────────────────────────────────" -ForegroundColor DarkGreen
        Write-Host "  │ $json" -ForegroundColor DarkGreen
        Write-Host "  └─────────────────────────────────────────────" -ForegroundColor DarkGreen
    }
    return $result
}

# ── Banner ───────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Fabric Environment Info                                    ║" -ForegroundColor Cyan
Write-Host "╠══════════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
Write-Host "║  Resource Group : $ResourceGroup" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# ── Authenticate ─────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "  Authenticating..." -ForegroundColor Gray

$account = az account show -o json 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Error "Not logged in. Run 'az login' first."
    exit 1
}
$subscriptionId = $account.id
$tenantId = $account.tenantId
Write-Host "  Subscription : $($account.name) ($subscriptionId)" -ForegroundColor Gray
Write-Host "  Tenant       : $tenantId" -ForegroundColor Gray

$fabricToken = (az account get-access-token --resource "https://api.fabric.microsoft.com" --query accessToken -o tsv 2>$null)
if (-not $fabricToken) {
    Write-Error "Failed to get Fabric API token. Ensure you have access to Microsoft Fabric."
    exit 1
}
$fabricHeaders = @{ Authorization = "Bearer $fabricToken" }

# ══════════════════════════════════════════════════════════════════════════════════
#  1. TENANT SETTINGS (networking-related)
# ══════════════════════════════════════════════════════════════════════════════════

Write-Section "1. Fabric Tenant Settings (networking)"

$networkingSettings = @(
    'ServicePrincipalAccess',
    'AzurePrivateLinks',
    'BlockPublicInternetAccess',
    'WorkspaceInboundNRR',
    'Spark.WorkspaceOutboundAccessProtection',
    'VNETDataGatewayEnabled'
)

try {
    $tenantSettings = Invoke-FabricApi -Uri "https://api.fabric.microsoft.com/v1/admin/tenantsettings" `
        -Headers $fabricHeaders
    $allSettings = $tenantSettings.tenantSettings

    foreach ($settingName in $networkingSettings) {
        $setting = $allSettings | Where-Object { $_.settingName -eq $settingName }
        if ($setting) {
            $state = if ($setting.state -eq 'Enabled') { '✅ Enabled' } else { '❌ Disabled' }
            $title = if ($setting.title) { $setting.title } else { $settingName }
            Write-Host "     $state  $title" -ForegroundColor $(if ($setting.state -eq 'Enabled') { 'Green' } else { 'DarkGray' })
        } else {
            Write-Host "     ❓ $settingName (not found)" -ForegroundColor DarkGray
        }
    }
} catch {
    Write-WarnMsg "Cannot read tenant settings (requires Fabric Admin role)."
    Write-WarnMsg "Error: $($_.Exception.Message)"
}

# ══════════════════════════════════════════════════════════════════════════════════
#  2. WORKSPACES
# ══════════════════════════════════════════════════════════════════════════════════

Write-Section "2. Fabric Workspaces"

try {
    $allWorkspaces = @()
    $continuationUrl = "https://api.fabric.microsoft.com/v1/workspaces"

    while ($continuationUrl) {
        $wsPage = Invoke-FabricApi -Uri $continuationUrl -Headers $fabricHeaders
        $allWorkspaces += @($wsPage.value)
        # The Fabric API may use 'continuationUri' or 'continuationToken', and
        # the property may be absent entirely on the last page.
        $continuationUrl = $null
        if ($wsPage.PSObject.Properties['continuationUri'] -and $wsPage.continuationUri) {
            $continuationUrl = $wsPage.continuationUri
        } elseif ($wsPage.PSObject.Properties['continuationToken'] -and $wsPage.continuationToken) {
            $continuationUrl = "https://api.fabric.microsoft.com/v1/workspaces?continuationToken=$($wsPage.continuationToken)"
        }
    }

    if ($allWorkspaces.Count -eq 0) {
        Write-None "No workspaces found."
    } else {
        Write-Host "     Found $($allWorkspaces.Count) workspace(s):" -ForegroundColor Gray
        Write-Host ""
        Write-Host ("     {0,-38} {1,-35} {2,-12}" -f 'WORKSPACE ID', 'NAME', 'CAPACITY') -ForegroundColor DarkCyan
        Write-Host ("     {0,-38} {1,-35} {2,-12}" -f ('─' * 36), ('─' * 33), ('─' * 10)) -ForegroundColor DarkGray

        foreach ($ws in $allWorkspaces | Sort-Object displayName) {
            $capId = if ($ws.capacityId) { $ws.capacityId.Substring(0, 8) + '...' } else { '(none)' }
            Write-Host ("     {0,-38} {1,-35} {2,-12}" -f $ws.id, $ws.displayName.Substring(0, [Math]::Min(33, $ws.displayName.Length)), $capId) -ForegroundColor Gray
        }
    }
} catch {
    Write-WarnMsg "Cannot list workspaces: $($_.Exception.Message)"
    $allWorkspaces = @()
}

# ══════════════════════════════════════════════════════════════════════════════════
#  3. FABRIC CAPACITIES
# ══════════════════════════════════════════════════════════════════════════════════

Write-Section "3. Fabric Capacities (in subscription)"

$capacities = @(az resource list --resource-type 'Microsoft.Fabric/capacities' -o json 2>$null | ConvertFrom-Json)

if (-not $capacities -or $capacities.Count -eq 0) {
    Write-None "No Fabric capacities found in the current subscription."
} else {
    foreach ($cap in $capacities) {
        $detail = az rest --method GET --url "https://management.azure.com$($cap.id)?api-version=2023-11-01" 2>$null | ConvertFrom-Json
        $state = $detail.properties.state
        $sku = $detail.sku.name
        $rg = ($cap.id -split '/')[4]
        $icon = if ($state -eq 'Active') { '🟢' } elseif ($state -eq 'Paused') { '🟡' } else { '⚪' }
        Write-Host "     $icon $($cap.name)  SKU=$sku  State=$state  RG=$rg  Region=$($cap.location)" -ForegroundColor Gray
    }
}

# ══════════════════════════════════════════════════════════════════════════════════
#  4. TENANT-LEVEL PRIVATE LINK SERVICES
# ══════════════════════════════════════════════════════════════════════════════════

Write-Section "4. Tenant-Level Private Link Services"
Write-Host "     Resource type: Microsoft.PowerBI/privateLinkServicesForPowerBI" -ForegroundColor DarkGray

$tenantPls = @(az resource list --resource-type 'Microsoft.PowerBI/privateLinkServicesForPowerBI' `
    -o json 2>$null | ConvertFrom-Json)

if (-not $tenantPls -or $tenantPls.Count -eq 0) {
    Write-None "No tenant-level PLS found in the subscription."
} else {
    foreach ($pls in $tenantPls) {
        $rg = ($pls.id -split '/')[4]
        Write-OK "$($pls.name)  RG=$rg  Region=$($pls.location)"
    }
}

# ── Private Endpoints targeting tenant PLS ──────────────────────────────────────

Write-Host ""
Write-Host "     Private Endpoints (tenant-level, in RG '$ResourceGroup'):" -ForegroundColor DarkCyan

$allPEs = @(az network private-endpoint list --resource-group $ResourceGroup -o json 2>$null | ConvertFrom-Json)

$tenantPEs = @()
if ($allPEs) {
    $tenantPEs = @($allPEs | Where-Object {
        $_.privateLinkServiceConnections | Where-Object {
            $_.groupIds -contains 'Tenant'
        }
    })
}

if ($tenantPEs.Count -eq 0) {
    Write-None "No tenant-level PEs found in '$ResourceGroup'."
} else {
    foreach ($pe in $tenantPEs) {
        $conn = $pe.privateLinkServiceConnections[0]
        $status = $conn.privateLinkServiceConnectionState.status
        $subnet = ($pe.subnet.id -split '/')[-1]
        $vnet = ($pe.subnet.id -split '/')[-3]
        Write-Item "$($pe.name)  Status=$status  VNet=$vnet/$subnet"
    }
}

# ══════════════════════════════════════════════════════════════════════════════════
#  5. WORKSPACE-LEVEL PRIVATE LINK SERVICES
# ══════════════════════════════════════════════════════════════════════════════════

Write-Section "5. Workspace-Level Private Link Services"
Write-Host "     Resource type: Microsoft.Fabric/privateLinkServicesForFabric" -ForegroundColor DarkGray

$wsPls = @(az resource list --resource-type 'Microsoft.Fabric/privateLinkServicesForFabric' `
    -o json 2>$null | ConvertFrom-Json)

if (-not $wsPls -or $wsPls.Count -eq 0) {
    Write-None "No workspace-level PLS found in the subscription."
} else {
    foreach ($pls in $wsPls) {
        $rg = ($pls.id -split '/')[4]
        # Get details to find the linked workspace ID
        $plsDetail = az rest --method GET --url "https://management.azure.com$($pls.id)?api-version=2024-06-01" 2>$null | ConvertFrom-Json
        $wsId = $plsDetail.properties.workspaceId
        $wsName = ''
        if ($wsId -and $allWorkspaces) {
            $match = $allWorkspaces | Where-Object { $_.id -eq $wsId }
            if ($match) { $wsName = " ($($match.displayName))" }
        }
        Write-OK "$($pls.name)  Workspace=$wsId$wsName  RG=$rg"
    }
}

# ── Private Endpoints targeting workspace PLS ───────────────────────────────────

Write-Host ""
Write-Host "     Private Endpoints (workspace-level, in RG '$ResourceGroup'):" -ForegroundColor DarkCyan

$wsPEs = @()
if ($allPEs) {
    $wsPEs = @($allPEs | Where-Object {
        $_.privateLinkServiceConnections | Where-Object {
            $_.groupIds -contains 'workspace'
        }
    })
}

if ($wsPEs.Count -eq 0) {
    Write-None "No workspace-level PEs found in '$ResourceGroup'."
} else {
    foreach ($pe in $wsPEs) {
        $conn = $pe.privateLinkServiceConnections[0]
        $status = $conn.privateLinkServiceConnectionState.status
        $subnet = ($pe.subnet.id -split '/')[-1]
        $vnet = ($pe.subnet.id -split '/')[-3]
        Write-Item "$($pe.name)  Status=$status  VNet=$vnet/$subnet"
    }
}

# ══════════════════════════════════════════════════════════════════════════════════
#  6. PRIVATE DNS ZONES
# ══════════════════════════════════════════════════════════════════════════════════

Write-Section "6. Private DNS Zones (in RG '$ResourceGroup')"

$dnsZones = @(az network private-dns zone list --resource-group $ResourceGroup -o json 2>$null | ConvertFrom-Json)

$fabricZones = @(
    'privatelink.analysis.windows.net',
    'privatelink.pbidedicated.windows.net',
    'privatelink.prod.powerquery.microsoft.com',
    'privatelink.fabric.microsoft.com'
)

if (-not $dnsZones -or $dnsZones.Count -eq 0) {
    Write-None "No private DNS zones found."
} else {
    foreach ($zone in $dnsZones) {
        $isFabric = $zone.name -in $fabricZones
        $icon = if ($isFabric) { '🔗' } else { '  ' }

        $links = @(az network private-dns link vnet list `
            --resource-group $ResourceGroup --zone-name $zone.name `
            -o json 2>$null | ConvertFrom-Json)
        $linkNames = ($links | ForEach-Object { ($_.virtualNetwork.id -split '/')[-1] }) -join ', '
        if (-not $linkNames) { $linkNames = '(no VNet links)' }

        Write-Host "     $icon $($zone.name)  Records=$($zone.numberOfRecordSets)  Links=$linkNames" -ForegroundColor $(if ($isFabric) { 'White' } else { 'Gray' })
    }
    Write-Host ""
    Write-Host "     🔗 = Fabric/Power BI DNS zone" -ForegroundColor DarkGray
}

# ══════════════════════════════════════════════════════════════════════════════════
#  7. WORKSPACE ACCESS POLICIES (communication policies)
# ══════════════════════════════════════════════════════════════════════════════════

Write-Section "7. Workspace Network Policies"

if ($allWorkspaces.Count -eq 0) {
    Write-None "No workspaces to check."
} else {
    $checkedCount = 0
    foreach ($ws in $allWorkspaces | Sort-Object displayName) {
        try {
            $policy = Invoke-FabricApi `
                -Uri "https://api.fabric.microsoft.com/v1/workspaces/$($ws.id)/communicationPolicy" `
                -Headers $fabricHeaders
            $checkedCount++

            $inboundPolicy = 'unknown'
            if ($policy.PSObject.Properties['inboundPolicy']) {
                $inboundPolicy = $policy.inboundPolicy
            } elseif ($policy.PSObject.Properties['policy']) {
                $inboundPolicy = $policy.policy
            }

            $icon = if ($inboundPolicy -match 'deny|block') { '🔒' } else { '🌐' }
            Write-Host "     $icon $($ws.displayName): inbound=$inboundPolicy" -ForegroundColor Gray
        } catch {
            # Some workspaces may not support this API (e.g., no capacity)
            continue
        }
    }
    if ($checkedCount -eq 0) {
        Write-None "No workspaces returned communication policy data."
    }
}

# ══════════════════════════════════════════════════════════════════════════════════
#  DONE
# ══════════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  Info collection complete                                   ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
