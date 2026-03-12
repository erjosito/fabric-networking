<#
.SYNOPSIS
    Probes which VM SKUs are actually deployable in a given Azure region.

.DESCRIPTION
    Creates a temporary resource group, attempts to deploy VMs of various sizes
    in parallel, reports which succeeded and which failed, then cleans up.

.PARAMETER Location
    Azure region to test. Default: canadacentral

.PARAMETER MaxCores
    Maximum number of vCPUs per SKU to test. Default: 2

.PARAMETER OsType
    Operating system type: 'Windows' or 'Linux'. Default: Windows

.PARAMETER Family
    Optional filter: only test SKUs whose name matches this pattern (e.g. 'D*a*' for AMD D-series).
    Uses PowerShell -like matching. Default: '*' (all families).

.EXAMPLE
    .\vm_sku_probe.ps1
    .\vm_sku_probe.ps1 -MaxCores 4 -Family 'B*'
    .\vm_sku_probe.ps1 -Location eastus -MaxCores 2 -OsType Linux -Family 'D*a*'
#>

param(
    [string]$Location     = 'canadacentral',
    [int]$MaxCores        = 2,
    [ValidateSet('Windows','Linux')]
    [string]$OsType       = 'Windows',
    [string]$Family       = '*'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$tempRg = "skuprobe-$(Get-Random -Minimum 10000 -Maximum 99999)"

# ---------- Image references ----------
if ($OsType -eq 'Windows') {
    $publisher = 'MicrosoftWindowsDesktop'
    $offer     = 'windows-11'
    $sku       = 'win11-24h2-pro'
    $version   = 'latest'
} else {
    $publisher = 'Canonical'
    $offer     = '0001-com-ubuntu-server-jammy'
    $sku       = '22_04-lts-gen2'
    $version   = 'latest'
}

# ---------- 1. Discover candidate SKUs ----------
Write-Host "`n╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host   "║  VM SKU Availability Probe                       ║" -ForegroundColor Cyan
Write-Host   "╚══════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

Write-Host "[1/5] Listing VM sizes in $Location (max $MaxCores vCPUs, family '$Family', $OsType)..."
$allSizes = az vm list-sizes --location $Location -o json 2>$null | ConvertFrom-Json

$candidates = @($allSizes | Where-Object {
    $_.numberOfCores -le $MaxCores -and
    $_.name -like "Standard_$Family" -and
    # Filter out promo / isolated / confidential SKUs
    $_.name -notmatch '(Promo|_NP|_CC|_DC|_EC|_FX|_HB|_HX|_NC|_ND|_NV)'
} | Sort-Object { $_.numberOfCores }, { $_.memoryInMB }, { $_.name })

if ($candidates.Count -eq 0) {
    Write-Host "  No candidate SKUs found matching the criteria." -ForegroundColor Yellow
    exit 0
}

Write-Host "  Found $($candidates.Count) candidate SKU(s).`n"
$candidates | ForEach-Object {
    Write-Host ("    {0,-28} {1} vCPU  {2,5:N1} GB RAM" -f $_.name, $_.numberOfCores, ($_.memoryInMB / 1024))
}

# ---------- 2. Create temp resource group ----------
Write-Host "`n[2/5] Creating temporary resource group '$tempRg' in $Location..."
az group create --name $tempRg --location $Location --output none --only-show-errors
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create resource group."; exit 1 }
Write-Host "  Created." -ForegroundColor Green

# ---------- 3. Launch parallel VM creates ----------
Write-Host "`n[3/5] Launching $($candidates.Count) parallel VM creation attempts..."
Write-Host "  (Each VM uses --no-wait; failures are expected and intentional.)`n"

$password = "Probe$(Get-Random -Minimum 100000 -Maximum 999999)!Ab"
$jobs = @()

foreach ($c in $candidates) {
    $vmName = "probe-$($c.name -replace 'Standard_','' -replace '_','-')".ToLower()
    # Truncate to 64 char max for VM name
    if ($vmName.Length -gt 64) { $vmName = $vmName.Substring(0, 64) }

    Write-Host "    Launching $($c.name)..."
    az vm create `
        --resource-group $tempRg `
        --name $vmName `
        --location $Location `
        --size $c.name `
        --image "${publisher}:${offer}:${sku}:${version}" `
        --admin-username probeuser `
        --admin-password $password `
        --public-ip-address '""' `
        --nsg '""' `
        --no-wait `
        --output none `
        --only-show-errors 2>$null

    $jobs += [PSCustomObject]@{
        SkuName  = $c.name
        VmName   = $vmName
        VCPUs    = $c.numberOfCores
        MemoryGB = [math]::Round($c.memoryInMB / 1024, 1)
        Status   = 'Pending'
        Error    = ''
    }
}

# ---------- 4. Wait and collect results ----------
Write-Host "`n[4/5] Waiting for deployments to complete (this may take a few minutes)..."

$maxWaitSeconds = 300
$pollInterval   = 15
$elapsed        = 0

while ($elapsed -lt $maxWaitSeconds) {
    Start-Sleep -Seconds $pollInterval
    $elapsed += $pollInterval
    $allDone = $true

    foreach ($j in $jobs) {
        if ($j.Status -ne 'Pending') { continue }

        $provState = az vm show --resource-group $tempRg --name $j.VmName --query "provisioningState" -o tsv 2>$null
        if ($LASTEXITCODE -ne 0) {
            # VM doesn't exist — likely the create itself was rejected
            # Check if there's a failed deployment
            $depState = az deployment group show --resource-group $tempRg --name $j.VmName --query "properties.provisioningState" -o tsv 2>$null
            if ($depState -eq 'Failed') {
                $depError = az deployment group show --resource-group $tempRg --name $j.VmName --query "properties.error.details[0].message" -o tsv 2>$null
                $j.Status = 'Failed'
                $j.Error  = if ($depError) { $depError.Substring(0, [Math]::Min($depError.Length, 120)) } else { 'Deployment failed' }
            } else {
                $allDone = $false
            }
        } elseif ($provState -eq 'Succeeded') {
            $j.Status = 'Available'
        } elseif ($provState -eq 'Failed') {
            $j.Status = 'Failed'
            $j.Error  = 'VM provisioning failed'
        } else {
            $allDone = $false
        }
    }

    $done  = @($jobs | Where-Object { $_.Status -ne 'Pending' }).Count
    $total = $jobs.Count
    Write-Host "  [$elapsed s] $done / $total completed..."

    if ($allDone) { break }
}

# Mark any still-pending as timed out
$jobs | Where-Object { $_.Status -eq 'Pending' } | ForEach-Object { $_.Status = 'Timeout' }

# ---------- 5. Report results ----------
Write-Host "`n[5/5] Results:`n"

$available = @($jobs | Where-Object { $_.Status -eq 'Available' } | Sort-Object MemoryGB, SkuName)
$failed    = @($jobs | Where-Object { $_.Status -ne 'Available' } | Sort-Object SkuName)

if ($available.Count -gt 0) {
    Write-Host "  ✅ AVAILABLE SKUs ($($available.Count)):" -ForegroundColor Green
    Write-Host ("    {0,-28} {1,5} {2,8}" -f 'SKU', 'vCPU', 'RAM (GB)')
    Write-Host ("    {0,-28} {1,5} {2,8}" -f '---', '----', '--------')
    foreach ($a in $available) {
        Write-Host ("    {0,-28} {1,5} {2,8:N1}" -f $a.SkuName, $a.VCPUs, $a.MemoryGB) -ForegroundColor Green
    }
} else {
    Write-Host "  ⚠ No SKUs were available." -ForegroundColor Yellow
}

if ($failed.Count -gt 0) {
    Write-Host "`n  ❌ UNAVAILABLE / FAILED ($($failed.Count)):" -ForegroundColor Red
    foreach ($f in $failed) {
        $reason = if ($f.Error) { $f.Error } else { $f.Status }
        Write-Host ("    {0,-28} {1}" -f $f.SkuName, $reason) -ForegroundColor DarkGray
    }
}

# ---------- Cleanup ----------
Write-Host "`n  Deleting temporary resource group '$tempRg'..."
az group delete --name $tempRg --yes --no-wait --output none 2>$null
Write-Host "  Cleanup initiated (async). Resource group will be deleted in the background." -ForegroundColor Green
Write-Host "`nDone.`n"
