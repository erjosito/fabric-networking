<#
.SYNOPSIS
    Deploys the Fabric Networking test infrastructure to Azure.

.DESCRIPTION
    Creates a resource group and deploys all Bicep templates: VNets, AVD pools,
    Azure SQL, Storage, Log Analytics, VNet Flow Logs, Private Endpoints, and
    Network Security Perimeter. Optionally deploys the Fabric Private Link
    service with tenant-level Private Endpoints.

.PARAMETER ResourceGroup
    Name of the Azure resource group. Default: fabricnetworking

.PARAMETER Location
    Azure region. Default: canadacentral

.PARAMETER Prefix
    Naming prefix for all resources. Default: fabnet

.PARAMETER VmAdminPassword
    Password for AVD session host local admin. Will prompt if not provided.

.PARAMETER SqlEntraAdminObjectId
    Object ID of the Entra ID user/group to set as SQL Server admin.
    Auto-discovered from the current Azure CLI session if not provided.

.PARAMETER SqlEntraAdminName
    Display name of the Entra ID SQL admin.
    Auto-discovered from the current Azure CLI session if not provided.

.PARAMETER DeployFabricPrivateLink
    Also deploy the Fabric / Power BI tenant-level Private Link service and
    Private Endpoints. Requires "Azure Private Link" to be enabled in Fabric
    Admin > Tenant Settings first.

.PARAMETER SkipSessionHosts
    Skip deploying AVD session host VMs. Use on re-deploys to avoid
    re-running the DSC extension on already-registered hosts.

.EXAMPLE
    .\infra_deploy.ps1
    .\infra_deploy.ps1 -ResourceGroup "my-rg" -Location "northeurope" -SkipSessionHosts
    .\infra_deploy.ps1 -DeployFabricPrivateLink
#>

[CmdletBinding()]
param(
    [string]$ResourceGroup = "fabricnetworking",
    [string]$Location = "canadacentral",
    [string]$Prefix = "fabnet",
    [securestring]$VmAdminPassword,
    [string]$SqlEntraAdminObjectId,
    [string]$SqlEntraAdminName,
    [switch]$DeployFabricPrivateLink,
    [switch]$SkipSessionHosts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Prompt for VM password only when deploying session hosts ─────────────────────

$deploySessionHosts = -not $SkipSessionHosts

$vmPwd = ""
if ($deploySessionHosts) {
    if ($null -eq $VmAdminPassword -or $VmAdminPassword.Length -eq 0) {
        $VmAdminPassword = Read-Host -Prompt "Enter VM admin password" -AsSecureString
    }
    $vmPwd = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                 [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($VmAdminPassword))
}

# ── Discover current signed-in user ─────────────────────────────────────────────

Write-Host "Discovering current user from Azure CLI session..." -ForegroundColor Yellow
$userObjectId    = az ad signed-in-user show --query id -o tsv --only-show-errors
$userDisplayName = az ad signed-in-user show --query displayName -o tsv --only-show-errors
$userUpn         = az ad signed-in-user show --query userPrincipalName -o tsv --only-show-errors
Write-Host "      Signed-in user: $userDisplayName ($userUpn)" -ForegroundColor Green

if ([string]::IsNullOrEmpty($SqlEntraAdminObjectId)) { $SqlEntraAdminObjectId = $userObjectId }
if ([string]::IsNullOrEmpty($SqlEntraAdminName))     { $SqlEntraAdminName = $userDisplayName }

# ── Banner ──────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Fabric Networking Infrastructure Deployment     ║" -ForegroundColor Cyan
Write-Host "╠══════════════════════════════════════════════════╣" -ForegroundColor Cyan
Write-Host "║  Resource Group : $ResourceGroup" -ForegroundColor Cyan
Write-Host "║  Location       : $Location" -ForegroundColor Cyan
Write-Host "║  Prefix         : $Prefix" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# ── Resolve template path relative to this script ──────────────────────────────

$scriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Definition
$templateFile = Join-Path $scriptDir "infra" "main.bicep"

if (-not (Test-Path $templateFile)) {
    Write-Error "Bicep template not found at $templateFile"
    exit 1
}

# ── Register resource providers ─────────────────────────────────────────────────

$providers = @(
    "Microsoft.DesktopVirtualization",
    "Microsoft.Network",
    "Microsoft.Sql",
    "Microsoft.Storage",
    "Microsoft.OperationalInsights",
    "Microsoft.Insights"
)

Write-Host "[1/7] Registering resource providers..." -ForegroundColor Yellow
foreach ($p in $providers) {
    az provider register --namespace $p --only-show-errors | Out-Null
}
Write-Host "      Providers registered (propagation may take a few minutes)." -ForegroundColor Green

# ── Create resource group ───────────────────────────────────────────────────────

Write-Host "[2/7] Creating resource group '$ResourceGroup'..." -ForegroundColor Yellow
az group create --name $ResourceGroup --location $Location --output none --only-show-errors
Write-Host "      Resource group ready." -ForegroundColor Green

# ── Ensure Network Watcher exists ───────────────────────────────────────────────

Write-Host "[3/7] Ensuring Network Watcher exists in '$Location'..." -ForegroundColor Yellow
az network watcher configure `
    --resource-group NetworkWatcherRG `
    --locations $Location `
    --enabled true `
    --output none --only-show-errors 2>$null
Write-Host "      Network Watcher confirmed." -ForegroundColor Green

# ── Deploy Bicep template ──────────────────────────────────────────────────────

Write-Host "[4/7] Deploying infrastructure (this will take several minutes)..." -ForegroundColor Yellow
$deployResult = az deployment group create `
    --resource-group $ResourceGroup `
    --template-file $templateFile `
    --parameters `
        location=$Location `
        prefix=$Prefix `
        sqlEntraAdminObjectId=$SqlEntraAdminObjectId `
        sqlEntraAdminName=$SqlEntraAdminName `
    --output json --only-show-errors

if ($LASTEXITCODE -ne 0) {
    Write-Error "Deployment failed. Check the Azure portal for details."
    exit 1
}

# ── Display outputs ─────────────────────────────────────────────────────────────

$outputs = ($deployResult | ConvertFrom-Json).properties.outputs

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  Deployment Complete                             ║" -ForegroundColor Green
Write-Host "╠══════════════════════════════════════════════════╣" -ForegroundColor Green
Write-Host "║  Log Analytics   : $($outputs.logAnalyticsWorkspaceId.value)" -ForegroundColor Green
Write-Host "║  SQL Server FQDN : $($outputs.sqlServerFqdn.value)" -ForegroundColor Green
Write-Host "║  SQL Database    : $($outputs.sqlDatabaseName.value)" -ForegroundColor Green
Write-Host "║  Data Storage    : $($outputs.dataStorageAccountName.value)" -ForegroundColor Green
Write-Host "║  Logging Storage : $($outputs.loggingStorageAccountName.value)" -ForegroundColor Green
Write-Host "║  VNet A          : $($outputs.vnetAId.value)" -ForegroundColor Green
Write-Host "║  VNet B          : $($outputs.vnetBId.value)" -ForegroundColor Green
Write-Host "║  AVD Pool A      : $($outputs.avdHostPoolAName.value)" -ForegroundColor Green
Write-Host "║  AVD Pool B      : $($outputs.avdHostPoolBName.value)" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""

# ── Deploy session host VMs (separate step — token is retrieved via CLI) ────────

$sessionHostTemplate = Join-Path $scriptDir "infra" "modules" "avd-sessionhost.bicep"

if ($deploySessionHosts) {
    Write-Host "[5/7] Deploying AVD session host VMs..." -ForegroundColor Yellow
    Write-Host "      ⏳ This step provisions VMs, installs Entra ID join and the AVD agent." -ForegroundColor DarkYellow
    Write-Host "      ⏳ Expect ~10-15 minutes. Both VMs deploy in parallel." -ForegroundColor DarkYellow

    $hostPools = @(
        @{ Label = 'A'; HpName = $outputs.avdHostPoolAName.value; SubnetId = $outputs.avdSubnetAId.value; VmName = "$Prefix-vm-a" },
        @{ Label = 'B'; HpName = $outputs.avdHostPoolBName.value; SubnetId = $outputs.avdSubnetBId.value; VmName = "$Prefix-vm-b" }
    )

    # Retrieve tokens and kick off deployments in parallel (--no-wait)
    $deploymentsToWait = @()

    foreach ($hp in $hostPools) {
        # Check if VM already exists (idempotency)
        $existingVm = az vm show --resource-group $ResourceGroup --name $hp.VmName --query id -o tsv 2>$null
        if ($existingVm) {
            Write-Host "      Session host $($hp.VmName) already exists — skipping." -ForegroundColor Yellow
            continue
        }

        Write-Host "      Retrieving registration token for $($hp.HpName)..." -ForegroundColor Gray
        $tokenJson = az desktopvirtualization hostpool retrieve-registration-token `
            --name $hp.HpName `
            --resource-group $ResourceGroup `
            --output json --only-show-errors
        $regToken = ($tokenJson | ConvertFrom-Json).token

        if ([string]::IsNullOrEmpty($regToken)) {
            Write-Error "Failed to retrieve registration token for $($hp.HpName)."
            exit 1
        }

        $deployName = "sessionHost$($hp.Label)"
        Write-Host "      Launching deployment '$deployName' for $($hp.VmName)..." -ForegroundColor Gray
        az deployment group create `
            --resource-group $ResourceGroup `
            --template-file $sessionHostTemplate `
            --name $deployName `
            --no-wait `
            --parameters `
                name=$($hp.VmName) `
                location=$Location `
                subnetId=$($hp.SubnetId) `
                vmSize='Standard_D2s_v5' `
                adminUsername='azureuser' `
                adminPassword=$vmPwd `
                hostPoolName=$($hp.HpName) `
                registrationToken=$regToken `
            --output none --only-show-errors

        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to start deployment for $($hp.VmName)."
            exit 1
        }
        $deploymentsToWait += $deployName
    }

    # Wait for all parallel deployments to complete
    if ($deploymentsToWait.Count -gt 0) {
        Write-Host "      Waiting for $($deploymentsToWait.Count) deployment(s) to complete..." -ForegroundColor Gray
        foreach ($depName in $deploymentsToWait) {
            az deployment group wait `
                --resource-group $ResourceGroup `
                --name $depName `
                --created --only-show-errors 2>$null

            $depResult = az deployment group show `
                --resource-group $ResourceGroup `
                --name $depName `
                --query properties.provisioningState -o tsv --only-show-errors 2>$null

            if ($depResult -eq 'Succeeded') {
                Write-Host "      ✅ $depName completed successfully." -ForegroundColor Green
            } else {
                Write-Error "Deployment '$depName' finished with state: $depResult. Check the Azure portal for details."
                exit 1
            }
        }
    }
} else {
    Write-Host "[5/7] Skipping session host VMs (use without -SkipSessionHosts to deploy)." -ForegroundColor Yellow
}

# ── Configure AVD access for current user ───────────────────────────────────────

Write-Host "[6/7] Configuring AVD access for $userDisplayName..." -ForegroundColor Yellow

$subscriptionId = az account show --query id -o tsv --only-show-errors
$rgScope = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup"

# Assign "Virtual Machine User Login" on the resource group (Entra ID joined VMs)
Write-Host "      Assigning 'Virtual Machine User Login' role on resource group..." -ForegroundColor Yellow
az role assignment create `
    --assignee $userObjectId `
    --role "Virtual Machine User Login" `
    --scope $rgScope `
    --output none --only-show-errors 2>$null

# Assign "Desktop Virtualization User" on each application group (using Bicep output IDs)
$appGroups = @(
    @{ Name = $outputs.avdHostPoolAName.value + '-dag'; Id = $outputs.avdAppGroupAId.value },
    @{ Name = $outputs.avdHostPoolBName.value + '-dag'; Id = $outputs.avdAppGroupBId.value }
)

foreach ($ag in $appGroups) {
    Write-Host "      Assigning 'Desktop Virtualization User' on $($ag.Name)..." -ForegroundColor Yellow
    az role assignment create `
        --assignee $userObjectId `
        --role "Desktop Virtualization User" `
        --scope $($ag.Id) `
        --output none --only-show-errors 2>$null
}

Write-Host "      AVD access configured." -ForegroundColor Green
Write-Host ""

# ── AVD connection instructions ─────────────────────────────────────────────────

Write-Host "[7/7] Done!" -ForegroundColor Yellow

Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "║  How to connect to AVD                           ║" -ForegroundColor Magenta
Write-Host "╠══════════════════════════════════════════════════╣" -ForegroundColor Magenta
Write-Host "║                                                  ║" -ForegroundColor Magenta
Write-Host "║  RBAC roles and app group assignments have been  ║" -ForegroundColor Magenta
Write-Host "║  configured for: $userUpn" -ForegroundColor Magenta
Write-Host "║                                                  ║" -ForegroundColor Magenta
Write-Host "║  Connect using one of these clients:             ║" -ForegroundColor Magenta
Write-Host "║                                                  ║" -ForegroundColor Magenta
Write-Host "║    Windows Desktop:  https://aka.ms/AVDClient    ║" -ForegroundColor Magenta
Write-Host "║    Web client:                                   ║" -ForegroundColor Magenta
Write-Host "║      https://client.wvd.microsoft.com/arm/       ║" -ForegroundColor Magenta
Write-Host "║        webclient/index.html                      ║" -ForegroundColor Magenta
Write-Host "║                                                  ║" -ForegroundColor Magenta
Write-Host "║  Sign in with your Entra ID credentials.         ║" -ForegroundColor Magenta
Write-Host "║  The desktops will appear under 'Workspaces'.    ║" -ForegroundColor Magenta
Write-Host "║                                                  ║" -ForegroundColor Magenta
Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Magenta
Write-Host ""

# Clean up plain-text password from memory
$vmPwd = $null
[System.GC]::Collect()
