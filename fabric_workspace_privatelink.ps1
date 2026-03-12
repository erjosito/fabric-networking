<#
.SYNOPSIS
    Deploys workspace-level Fabric Private Link with Private Endpoints.

.DESCRIPTION
    Uses the Fabric REST API to discover and list workspaces, then deploys
    Microsoft.Fabric/privateLinkServicesForFabric for the selected workspace
    with a Private DNS zone and Private Endpoints on both VNets.

    Prerequisites:
      1. Enable "Configure workspace-level inbound network rules" in Fabric
         Admin Portal > Tenant Settings
      2. The workspace must be assigned to a Fabric capacity (F SKU)
      3. Register the Microsoft.Fabric resource provider in the subscription
      4. Run infra_deploy.ps1 first to create VNets and infrastructure

.PARAMETER ResourceGroup
    Resource group containing the infrastructure. Default: fabricnetworking

.PARAMETER Location
    Azure region. Default: canadacentral

.PARAMETER Prefix
    Resource naming prefix. Default: fabnet

.PARAMETER WorkspaceId
    Fabric workspace ID (GUID). If not provided, the script queries the
    Fabric REST API and lets you choose from your workspaces.

.PARAMETER WorkspaceSuffix
    Short alias for naming Azure resources (e.g. "analytics"). Auto-derived
    from the workspace name if not provided.

.PARAMETER DenyPublicAccess
    After deployment, use the Fabric API to deny public access to the
    workspace, restricting it to private link connections only.

.PARAMETER DebugApi
    Print all Fabric REST API requests and responses to the console.

.EXAMPLE
    .\fabric_workspace_privatelink.ps1
    .\fabric_workspace_privatelink.ps1 -WorkspaceId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    .\fabric_workspace_privatelink.ps1 -DenyPublicAccess
#>

[CmdletBinding()]
param(
    [string]$ResourceGroup = "fabricnetworking",
    [string]$Location = "canadacentral",
    [string]$Prefix = "fabnet",
    [string]$WorkspaceId,
    [string]$WorkspaceSuffix,
    [switch]$DenyPublicAccess,
    [switch]$DebugApi
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Debug helper: log REST API calls ────────────────────────────────────────────

function Invoke-FabricApi {
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [string]$Method = "Get",
        [string]$Body
    )
    if ($DebugApi) {
        Write-Host ""
        Write-Host "  ┌─ REST API Call ─────────────────────────────" -ForegroundColor DarkYellow
        Write-Host "  │ $Method $Uri" -ForegroundColor DarkYellow
        Write-Host "  │ Authorization: Bearer <token>" -ForegroundColor DarkYellow
        if ($Body) { Write-Host "  │ Body: $Body" -ForegroundColor DarkYellow }
        Write-Host "  └─────────────────────────────────────────────" -ForegroundColor DarkYellow
    }
    $params = @{ Uri = $Uri; Headers = $Headers; Method = $Method }
    if ($Body) { $params.Body = $Body; $params.ContentType = "application/json" }
    $result = Invoke-RestMethod @params
    if ($DebugApi) {
        $resultJson = $result | ConvertTo-Json -Depth 5 -Compress
        if ($resultJson.Length -gt 2000) { $resultJson = $resultJson.Substring(0, 2000) + "... (truncated)" }
        Write-Host "  ┌─ Response ──────────────────────────────────" -ForegroundColor DarkGreen
        Write-Host "  │ $resultJson" -ForegroundColor DarkGreen
        Write-Host "  └─────────────────────────────────────────────" -ForegroundColor DarkGreen
    }
    return $result
}

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Fabric Workspace-Level Private Link Deployment  ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# ── Resolve template path ───────────────────────────────────────────────────────

$scriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Definition
$templateFile = Join-Path $scriptDir "infra" "fabric-workspace-private-link.bicep"

if (-not (Test-Path $templateFile)) {
    Write-Error "Bicep template not found at $templateFile"
    exit 1
}

# ── Discover tenant ID ──────────────────────────────────────────────────────────

Write-Host "[1/5] Discovering tenant ID..." -ForegroundColor Yellow
$tenantId = az account show --query tenantId -o tsv --only-show-errors
Write-Host "      Tenant ID: $tenantId" -ForegroundColor Green

# ── Acquire Fabric API token ────────────────────────────────────────────────────

Write-Host "[2/5] Acquiring Fabric REST API token..." -ForegroundColor Yellow
$fabricToken = az account get-access-token `
    --resource "https://api.fabric.microsoft.com" `
    --query accessToken -o tsv --only-show-errors

$headers = @{
    "Authorization" = "Bearer $fabricToken"
    "Content-Type"  = "application/json"
}
Write-Host "      Token acquired." -ForegroundColor Green

# ── Discover or select workspace ────────────────────────────────────────────────

if ([string]::IsNullOrEmpty($WorkspaceId)) {
    Write-Host "[3/5] Querying Fabric REST API for workspaces..." -ForegroundColor Yellow

    $workspaces = @()
    $continuationUri = "https://api.fabric.microsoft.com/v1/workspaces"

    while ($continuationUri) {
        $response = Invoke-FabricApi -Uri $continuationUri -Headers $headers -Method Get
        $workspaces += @($response.value)
        $continuationUri = $null
        if ($response.PSObject.Properties['continuationUri'] -and $response.continuationUri) {
            $continuationUri = $response.continuationUri
        } elseif ($response.PSObject.Properties['continuationToken'] -and $response.continuationToken) {
            $continuationUri = "https://api.fabric.microsoft.com/v1/workspaces?continuationToken=$($response.continuationToken)"
        }
    }

    if ($workspaces.Count -eq 0) {
        Write-Error "No workspaces found. Ensure you have access to at least one Fabric workspace."
        exit 1
    }

    Write-Host ""
    Write-Host "  Available Workspaces:" -ForegroundColor Cyan
    Write-Host "  ─────────────────────" -ForegroundColor Cyan
    for ($i = 0; $i -lt $workspaces.Count; $i++) {
        $ws = $workspaces[$i]
        $capacityInfo = if ($ws.capacityId) { " [Capacity: $($ws.capacityId)]" } else { " [No capacity]" }
        Write-Host "  [$($i + 1)] $($ws.displayName)$capacityInfo" -ForegroundColor White
        Write-Host "      ID: $($ws.id)" -ForegroundColor DarkGray
    }
    Write-Host ""

    do {
        $selection = Read-Host "Select workspace number (1-$($workspaces.Count))"
        $selIndex = [int]$selection - 1
    } while ($selIndex -lt 0 -or $selIndex -ge $workspaces.Count)

    $selectedWorkspace = $workspaces[$selIndex]
    $WorkspaceId = $selectedWorkspace.id
    $workspaceName = $selectedWorkspace.displayName

    Write-Host "      Selected: $workspaceName ($WorkspaceId)" -ForegroundColor Green
} else {
    Write-Host "[3/5] Using provided workspace ID: $WorkspaceId" -ForegroundColor Yellow

    # Fetch workspace name via API
    try {
        $wsResponse = Invoke-FabricApi `
            -Uri "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId" `
            -Headers $headers -Method Get
        $workspaceName = $wsResponse.displayName
        Write-Host "      Workspace name: $workspaceName" -ForegroundColor Green
    } catch {
        $workspaceName = "workspace"
        Write-Host "      Could not resolve workspace name, using default." -ForegroundColor DarkYellow
    }
}

# Derive suffix from workspace name if not provided
if ([string]::IsNullOrEmpty($WorkspaceSuffix)) {
    $WorkspaceSuffix = ($workspaceName -replace '[^a-zA-Z0-9]', '' -replace '\s+', '').ToLower()
    if ($WorkspaceSuffix.Length -gt 20) { $WorkspaceSuffix = $WorkspaceSuffix.Substring(0, 20) }
    Write-Host "      Resource suffix: $WorkspaceSuffix" -ForegroundColor Green
}

# ── Discover VNet and subnet IDs ────────────────────────────────────────────────

Write-Host "[4/5] Discovering VNet and subnet IDs from resource group..." -ForegroundColor Yellow

$vnetAId = az network vnet show `
    --resource-group $ResourceGroup --name "${Prefix}-vnet-a" `
    --query id -o tsv --only-show-errors
$vnetBId = az network vnet show `
    --resource-group $ResourceGroup --name "${Prefix}-vnet-b" `
    --query id -o tsv --only-show-errors

$peSubnetAId = az network vnet subnet show `
    --resource-group $ResourceGroup --vnet-name "${Prefix}-vnet-a" --name "snet-pe" `
    --query id -o tsv --only-show-errors
$peSubnetBId = az network vnet subnet show `
    --resource-group $ResourceGroup --vnet-name "${Prefix}-vnet-b" --name "snet-pe" `
    --query id -o tsv --only-show-errors

Write-Host "      VNet A: $vnetAId" -ForegroundColor Green
Write-Host "      VNet B: $vnetBId" -ForegroundColor Green

# ── Register Microsoft.Fabric resource provider ────────────────────────────────

az provider register --namespace Microsoft.Fabric --only-show-errors | Out-Null

# ── Preview ARM template ────────────────────────────────────────────────────────

$vnetIdsJson     = ConvertTo-Json @($vnetAId, $vnetBId) -Compress
$peSubnetIdsJson = ConvertTo-Json @($peSubnetAId, $peSubnetBId) -Compress

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor DarkCyan
Write-Host "║  ARM Template Preview (compiled from Bicep)      ║" -ForegroundColor DarkCyan
Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor DarkCyan

$armJson = az bicep build --file $templateFile --stdout 2>$null
$armPretty = $armJson | ConvertFrom-Json | ConvertTo-Json -Depth 20
Write-Host $armPretty -ForegroundColor DarkGray

Write-Host ""
Write-Host "  Parameters that will be applied:" -ForegroundColor DarkCyan
Write-Host "    location        = $Location" -ForegroundColor DarkGray
Write-Host "    prefix          = $Prefix" -ForegroundColor DarkGray
Write-Host "    tenantId        = $tenantId" -ForegroundColor DarkGray
Write-Host "    workspaceId     = $WorkspaceId" -ForegroundColor DarkGray
Write-Host "    workspaceSuffix = $WorkspaceSuffix" -ForegroundColor DarkGray
Write-Host "    vnetIds         = $vnetIdsJson" -ForegroundColor DarkGray
Write-Host "    peSubnetIds     = $peSubnetIdsJson" -ForegroundColor DarkGray
Write-Host ""

# ── Deploy Bicep template ───────────────────────────────────────────────────────

Write-Host "[5/5] Deploying Fabric workspace-level Private Link..." -ForegroundColor Yellow

$paramsObj = @{
    '`$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters = @{
        location        = @{ value = $Location }
        prefix          = @{ value = $Prefix }
        tenantId        = @{ value = $tenantId }
        workspaceId     = @{ value = $WorkspaceId }
        workspaceSuffix = @{ value = $WorkspaceSuffix }
        vnetIds         = @{ value = @($vnetAId, $vnetBId) }
        peSubnetIds     = @{ value = @($peSubnetAId, $peSubnetBId) }
    }
}
$paramsFile = Join-Path ([System.IO.Path]::GetTempPath()) "fabric-workspace-pl-params.json"
$paramsObj | ConvertTo-Json -Depth 5 | Set-Content -Path $paramsFile -Encoding UTF8

$deployResult = az deployment group create `
    --resource-group $ResourceGroup `
    --template-file $templateFile `
    --parameters "@$paramsFile" `
    --output json --only-show-errors

Remove-Item -Path $paramsFile -ErrorAction SilentlyContinue

if ($LASTEXITCODE -ne 0) {
    Write-Error "Deployment failed. Check the Azure portal for details."
    exit 1
}

$outputs = ($deployResult | ConvertFrom-Json).properties.outputs

# ── Optionally deny public access via Fabric API ───────────────────────────────

if ($DenyPublicAccess) {
    Write-Host ""
    Write-Host "Configuring workspace to deny public access via Fabric API..." -ForegroundColor Yellow

    $policyBody = @{
        communicationPolicy = @{
            rules = @(
                @{
                    id          = "block-public-access"
                    description = "Deny public internet access"
                    direction   = "Inbound"
                    action      = "Deny"
                    sourceAddressRanges = @("*")
                }
            )
        }
    } | ConvertTo-Json -Depth 5

    try {
        Invoke-FabricApi `
            -Uri "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/communicationPolicy" `
            -Headers $headers -Method Put -Body $policyBody
        Write-Host "      Public access DENIED for workspace $workspaceName." -ForegroundColor Green
        Write-Host "      Note: this setting can take up to 30 minutes to take effect." -ForegroundColor DarkYellow
    } catch {
        Write-Host "      WARNING: Could not set communication policy." -ForegroundColor DarkYellow
        Write-Host "      Error: $($_.Exception.Message)" -ForegroundColor DarkYellow
        Write-Host "      You can deny public access manually in the Fabric portal:" -ForegroundColor DarkYellow
        Write-Host "      Workspace Settings > Inbound networking > Allow selected networks only" -ForegroundColor DarkYellow
    }
}

# ── Summary ─────────────────────────────────────────────────────────────────────

$wsIdNoDashes = $WorkspaceId -replace '-', ''
$xyPrefix     = $wsIdNoDashes.Substring(0, 2)

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  Fabric Workspace Private Link — Deployed        ║" -ForegroundColor Green
Write-Host "╠══════════════════════════════════════════════════╣" -ForegroundColor Green
Write-Host "║  PLS Resource  : $($outputs.fabricWorkspacePlsName.value)" -ForegroundColor Green
Write-Host "║  Workspace     : $workspaceName" -ForegroundColor Green
Write-Host "║  Workspace ID  : $WorkspaceId" -ForegroundColor Green
Write-Host "║  Tenant ID     : $tenantId" -ForegroundColor Green
Write-Host "║                                                  ║" -ForegroundColor Green
Write-Host "║  Private DNS zone:                               ║" -ForegroundColor Green
Write-Host "║    privatelink.fabric.microsoft.com              ║" -ForegroundColor Green
Write-Host "║                                                  ║" -ForegroundColor Green
Write-Host "║  Private Endpoints on: vnet-a/snet-pe,           ║" -ForegroundColor Green
Write-Host "║                        vnet-b/snet-pe            ║" -ForegroundColor Green
Write-Host "║                                                  ║" -ForegroundColor Green
Write-Host "║  To verify from an AVD VM:                       ║" -ForegroundColor Green
Write-Host "║  nslookup ${wsIdNoDashes}.z${xyPrefix}.w.api.fabric.microsoft.com" -ForegroundColor Green
Write-Host "║  (should return a private IP)                    ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
