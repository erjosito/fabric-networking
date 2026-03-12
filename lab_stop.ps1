<#
.SYNOPSIS
    Stops and deallocates the Fabric Networking lab to save costs.

.DESCRIPTION
    Deallocates AVD session host VMs and suspends any Microsoft Fabric capacities
    found in the resource group. Resources that are already stopped are skipped.

.PARAMETER ResourceGroup
    Name of the Azure resource group. Default: fabricnetworking

.PARAMETER Prefix
    Naming prefix used when deploying resources. Default: fabnet

.PARAMETER SkipVMs
    Skip deallocating AVD session host VMs.

.PARAMETER SkipFabricCapacity
    Skip suspending Fabric capacities.

.EXAMPLE
    .\lab_stop.ps1
    .\lab_stop.ps1 -SkipFabricCapacity
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
Write-Host '║  Fabric Networking Lab — STOP                              ║' -ForegroundColor Magenta
Write-Host '╚══════════════════════════════════════════════════════════════╝' -ForegroundColor Magenta
Write-Host "   Resource Group : $ResourceGroup"
Write-Host "   Prefix         : $Prefix"

# ── Step 1: Deallocate AVD Session Host VMs ──────────────────────────────────

if (-not $SkipVMs) {
    Write-Step 'Deallocating AVD session host VMs...'

    $vms = az vm list --resource-group $ResourceGroup --query "[?starts_with(name, '$Prefix-vm-')]" -o json 2>$null | ConvertFrom-Json
    if (-not $vms -or $vms.Count -eq 0) {
        Write-Skip 'No VMs found matching prefix.'
    } else {
        foreach ($vm in $vms) {
            $vmName = $vm.name
            # Check current power state
            $status = az vm get-instance-view --resource-group $ResourceGroup --name $vmName `
                --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus" -o tsv 2>$null
            if ($status -match 'deallocated') {
                Write-Skip "$vmName is already deallocated."
            } else {
                Write-Host "   ⏳ Deallocating $vmName (was: $status)..." -ForegroundColor Gray
                az vm deallocate --resource-group $ResourceGroup --name $vmName --no-wait 2>$null
                Write-Ok "$vmName deallocate command sent (--no-wait)."
            }
        }
    }
} else {
    Write-Step 'Skipping VM deallocation (--SkipVMs).'
}

# ── Step 2: Suspend Fabric Capacities ────────────────────────────────────────

if (-not $SkipFabricCapacity) {
    Write-Step 'Suspending Fabric capacities...'

    $subId = az account show --query id -o tsv
    $capacities = az resource list --resource-group $ResourceGroup `
        --resource-type 'Microsoft.Fabric/capacities' -o json 2>$null | ConvertFrom-Json

    if (-not $capacities -or $capacities.Count -eq 0) {
        Write-Skip 'No Fabric capacities found in resource group.'
    } else {
        foreach ($cap in $capacities) {
            $capName = $cap.name
            # Check current state
            $detail = az rest --method GET `
                --url "https://management.azure.com$($cap.id)?api-version=2023-11-01" 2>$null | ConvertFrom-Json
            $state = $detail.properties.state

            if ($state -eq 'Paused') {
                Write-Skip "$capName is already paused."
            } else {
                Write-Host "   ⏳ Suspending capacity $capName (was: $state)..." -ForegroundColor Gray
                az rest --method POST `
                    --url "https://management.azure.com$($cap.id)/suspend?api-version=2023-11-01" 2>$null
                Write-Ok "$capName suspended."
            }
        }
    }
} else {
    Write-Step 'Skipping Fabric capacity suspension (--SkipFabricCapacity).'
}

# ── Done ─────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '╔══════════════════════════════════════════════════════════════╗' -ForegroundColor Green
Write-Host '║  Lab stopped. Re-start with .\lab_start.ps1                ║' -ForegroundColor Green
Write-Host '╚══════════════════════════════════════════════════════════════╝' -ForegroundColor Green
Write-Host ''
