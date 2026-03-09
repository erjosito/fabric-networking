<#
.SYNOPSIS
    Deploys tenant-level Fabric / Power BI Private Link with Private Endpoints.

.DESCRIPTION
    Discovers tenant ID and VNet details from the existing infrastructure deployment,
    checks the Fabric Admin API to verify the "Azure Private Link" tenant setting is
    enabled, then deploys the Microsoft.PowerBI/privateLinkServicesForPowerBI resource
    with Private DNS zones and Private Endpoints on both VNets.

    Prerequisites:
      1. Enable "Azure Private Link" in Fabric Admin Portal > Tenant Settings
      2. Wait ~15 minutes for the FQDN to propagate
      3. Run infra_deploy.ps1 first to create VNets and infrastructure

.PARAMETER ResourceGroup
    Resource group containing the infrastructure. Default: fabricnetworking

.PARAMETER Location
    Azure region. Default: canadacentral

.PARAMETER Prefix
    Resource naming prefix. Default: fabnet

.PARAMETER SkipFabricCheck
    Skip the Fabric API check for the Private Link tenant setting.

.PARAMETER DebugApi
    Print all Fabric REST API requests and responses to the console.

.EXAMPLE
    .\fabric_tenant_privatelink.ps1
    .\fabric_tenant_privatelink.ps1 -SkipFabricCheck
#>

[CmdletBinding()]
param(
    [string]$ResourceGroup = "fabricnetworking",
    [string]$Location = "canadacentral",
    [string]$Prefix = "fabnet",
    [switch]$SkipFabricCheck,
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
Write-Host "║  Fabric Tenant-Level Private Link Deployment     ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# ── Resolve template path ───────────────────────────────────────────────────────

$scriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Definition
$templateFile = Join-Path $scriptDir "infra" "fabric-private-link.bicep"

if (-not (Test-Path $templateFile)) {
    Write-Error "Bicep template not found at $templateFile"
    exit 1
}

# ── Discover tenant ID ──────────────────────────────────────────────────────────

Write-Host "[1/4] Discovering tenant ID..." -ForegroundColor Yellow
$tenantId = az account show --query tenantId -o tsv --only-show-errors
Write-Host "      Tenant ID: $tenantId" -ForegroundColor Green

# ── Check Fabric Admin API for Private Link setting ─────────────────────────────

if (-not $SkipFabricCheck) {
    Write-Host "[2/4] Checking Fabric tenant settings via REST API..." -ForegroundColor Yellow
    try {
        $fabricToken = az account get-access-token `
            --resource "https://api.fabric.microsoft.com" `
            --query accessToken -o tsv --only-show-errors

        $headers = @{ "Authorization" = "Bearer $fabricToken" }
        $response = Invoke-FabricApi `
            -Uri "https://api.fabric.microsoft.com/v1/admin/tenantsettings" `
            -Headers $headers -Method Get

        $plSetting = $response.tenantSettings | Where-Object { $_.settingName -eq "PrivateLinks" }

        if ($plSetting) {
            if ($plSetting.state -eq "Enabled") {
                Write-Host "      Azure Private Link tenant setting: ENABLED" -ForegroundColor Green
            } else {
                Write-Host ""
                Write-Host "  WARNING: 'Azure Private Link' is NOT enabled in Fabric tenant settings." -ForegroundColor Red
                Write-Host "  Enable it in Fabric Admin Portal > Tenant Settings > Azure Private Link" -ForegroundColor Red
                Write-Host "  and wait ~15 minutes before running this script." -ForegroundColor Red
                Write-Host ""
                exit 1
            }
        } else {
            Write-Host "      Could not find 'PrivateLinks' setting. Proceeding anyway..." -ForegroundColor DarkYellow
        }
    } catch {
        Write-Host "      Could not query Fabric API (admin permissions may be required)." -ForegroundColor DarkYellow
        Write-Host "      Error: $($_.Exception.Message)" -ForegroundColor DarkYellow
        Write-Host "      Proceeding — ensure the Private Link tenant setting is enabled." -ForegroundColor DarkYellow
    }
} else {
    Write-Host "[2/4] Skipping Fabric API check (--SkipFabricCheck)." -ForegroundColor DarkYellow
}

# ── Discover VNet and subnet IDs from existing deployment ───────────────────────

Write-Host "[3/4] Discovering VNet and subnet IDs from resource group..." -ForegroundColor Yellow

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

# ── Register Microsoft.PowerBI resource provider ───────────────────────────────

az provider register --namespace Microsoft.PowerBI --only-show-errors | Out-Null

# ── Preview ARM template ────────────────────────────────────────────────────────

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor DarkCyan
Write-Host "║  ARM Template Preview (compiled from Bicep)      ║" -ForegroundColor DarkCyan
Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor DarkCyan

$armJson = az bicep build --file $templateFile --stdout 2>$null
Write-Host $armJson -ForegroundColor DarkGray

Write-Host ""
Write-Host "  Parameters that will be applied:" -ForegroundColor DarkCyan
Write-Host "    location     = $Location" -ForegroundColor DarkGray
Write-Host "    prefix       = $Prefix" -ForegroundColor DarkGray
Write-Host "    tenantId     = $tenantId" -ForegroundColor DarkGray
Write-Host "    vnetIds      = $vnetIdsJson" -ForegroundColor DarkGray
Write-Host "    peSubnetIds  = $peSubnetIdsJson" -ForegroundColor DarkGray
Write-Host ""

# ── Deploy Bicep template ───────────────────────────────────────────────────────

Write-Host "[4/4] Deploying Fabric tenant-level Private Link..." -ForegroundColor Yellow

$vnetIdsJson     = ConvertTo-Json @($vnetAId, $vnetBId) -Compress
$peSubnetIdsJson = ConvertTo-Json @($peSubnetAId, $peSubnetBId) -Compress

$deployResult = az deployment group create `
    --resource-group $ResourceGroup `
    --template-file $templateFile `
    --parameters `
        location=$Location `
        prefix=$Prefix `
        tenantId=$tenantId `
        vnetIds=$vnetIdsJson `
        peSubnetIds=$peSubnetIdsJson `
    --output json --only-show-errors

if ($LASTEXITCODE -ne 0) {
    Write-Error "Deployment failed. Check the Azure portal for details."
    exit 1
}

$outputs = ($deployResult | ConvertFrom-Json).properties.outputs

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  Fabric Tenant Private Link — Deployed           ║" -ForegroundColor Green
Write-Host "╠══════════════════════════════════════════════════╣" -ForegroundColor Green
Write-Host "║  PLS Resource : $($outputs.fabricPrivateLinkServiceName.value)" -ForegroundColor Green
Write-Host "║  Tenant ID    : $tenantId" -ForegroundColor Green
Write-Host "║                                                  ║" -ForegroundColor Green
Write-Host "║  Private DNS zones created:                      ║" -ForegroundColor Green
Write-Host "║    - privatelink.analysis.windows.net            ║" -ForegroundColor Green
Write-Host "║    - privatelink.pbidedicated.windows.net        ║" -ForegroundColor Green
Write-Host "║    - privatelink.prod.powerquery.microsoft.com   ║" -ForegroundColor Green
Write-Host "║                                                  ║" -ForegroundColor Green
Write-Host "║  Private Endpoints on: vnet-a/snet-pe,           ║" -ForegroundColor Green
Write-Host "║                        vnet-b/snet-pe            ║" -ForegroundColor Green
Write-Host "║                                                  ║" -ForegroundColor Green
Write-Host "║  To verify from an AVD VM:                       ║" -ForegroundColor Green

$tenantIdNoDashes = $tenantId -replace '-', ''
Write-Host "║  nslookup ${tenantIdNoDashes}-api.privatelink.analysis.windows.net" -ForegroundColor Green
Write-Host "║  (should return a private IP)                    ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
