<#
.SYNOPSIS
    Starts the Fabric Networking lab resources.

.DESCRIPTION
    Starts AVD session host VMs and resumes any Microsoft Fabric capacities
    found in the resource group. Resources that are already running are skipped.

.PARAMETER ResourceGroup
    Name of the Azure resource group. Default: fabricnetworking

.PARAMETER Prefix
    Naming prefix used when deploying resources. Default: fabnet

.PARAMETER SkipVMs
    Skip starting AVD session host VMs.

.PARAMETER SkipFabricCapacity
    Skip resuming Fabric capacities.

.EXAMPLE
    .\lab_start.ps1
    .\lab_start.ps1 -SkipFabricCapacity
#>

param(
    [string]$ResourceGroup = 'fabricnetworking',
    [string]$Prefix = 'fabnet',
    [switch]$SkipVMs,
    [switch]$SkipFabricCapacity
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$Msg) Write-Host "`n🔹 $Msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "   ✅ $Msg" -ForegroundColor Green }
function Write-Skip { param([string]$Msg) Write-Host "   ⏭️  $Msg" -ForegroundColor Yellow }

Write-Host ''
Write-Host '╔══════════════════════════════════════════════════════════════╗' -ForegroundColor Magenta
Write-Host '║  Fabric Networking Lab — START                             ║' -ForegroundColor Magenta
Write-Host '╚══════════════════════════════════════════════════════════════╝' -ForegroundColor Magenta
Write-Host "   Resource Group : $ResourceGroup"
Write-Host "   Prefix         : $Prefix"

# ── Step 1: Start AVD Session Host VMs ───────────────────────────────────────

if (-not $SkipVMs) {
    Write-Step 'Starting AVD session host VMs...'

    $vms = az vm list --resource-group $ResourceGroup --query "[?starts_with(name, '$Prefix-vm-')]" -o json 2>$null | ConvertFrom-Json
    if (-not $vms -or $vms.Count -eq 0) {
        Write-Skip 'No VMs found matching prefix.'
    } else {
        foreach ($vm in $vms) {
            $vmName = $vm.name
            $status = az vm get-instance-view --resource-group $ResourceGroup --name $vmName `
                --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus" -o tsv 2>$null
            if ($status -match 'running') {
                Write-Skip "$vmName is already running."
            } else {
                Write-Host "   ⏳ Starting $vmName (was: $status)..." -ForegroundColor Gray
                az vm start --resource-group $ResourceGroup --name $vmName --no-wait 2>$null
                Write-Ok "$vmName start command sent (--no-wait)."
            }
        }
    }
} else {
    Write-Step 'Skipping VM start (--SkipVMs).'
}

# ── Step 2: Resume Fabric Capacities ─────────────────────────────────────────

if (-not $SkipFabricCapacity) {
    Write-Step 'Resuming Fabric capacities...'

    $subId = az account show --query id -o tsv
    $capacities = az resource list --resource-group $ResourceGroup `
        --resource-type 'Microsoft.Fabric/capacities' -o json 2>$null | ConvertFrom-Json

    if (-not $capacities -or $capacities.Count -eq 0) {
        Write-Skip 'No Fabric capacities found in resource group.'
    } else {
        foreach ($cap in $capacities) {
            $capName = $cap.name
            $detail = az rest --method GET `
                --url "https://management.azure.com$($cap.id)?api-version=2023-11-01" 2>$null | ConvertFrom-Json
            $state = $detail.properties.state

            if ($state -eq 'Active') {
                Write-Skip "$capName is already active."
            } else {
                Write-Host "   ⏳ Resuming capacity $capName (was: $state)..." -ForegroundColor Gray
                az rest --method POST `
                    --url "https://management.azure.com$($cap.id)/resume?api-version=2023-11-01" 2>$null
                Write-Ok "$capName resumed."
            }
        }
    }
} else {
    Write-Step 'Skipping Fabric capacity resume (--SkipFabricCapacity).'
}

# ── Done ─────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '╔══════════════════════════════════════════════════════════════╗' -ForegroundColor Green
Write-Host '║  Lab started. Stop with .\lab_stop.ps1 to save costs.     ║' -ForegroundColor Green
Write-Host '╚══════════════════════════════════════════════════════════════╝' -ForegroundColor Green
Write-Host ''
