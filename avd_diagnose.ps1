<#
.SYNOPSIS
    Diagnoses the AVD configuration in the Fabric Networking lab.

.DESCRIPTION
    Runs a series of checks against the Azure Virtual Desktop resources deployed
    by infra_deploy.ps1 and reports findings with actionable guidance and links
    to Microsoft documentation.

.PARAMETER ResourceGroup
    Name of the Azure resource group. Default: fabricnetworking

.PARAMETER Prefix
    Naming prefix used when deploying resources. Default: fabnet

.EXAMPLE
    .\avd_diagnose.ps1
    .\avd_diagnose.ps1 -ResourceGroup "my-rg" -Prefix "mylab"
#>

[CmdletBinding()]
param(
    [string]$ResourceGroup = 'fabricnetworking',
    [string]$Prefix = 'fabnet'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Helpers ──────────────────────────────────────────────────────────────────────

$script:passCount = 0
$script:warnCount = 0
$script:failCount = 0
$script:skipCount = 0

function Write-Check   { param([string]$Msg) Write-Host "`n  🔍 $Msg" -ForegroundColor Cyan }
function Write-Pass    { param([string]$Msg) $script:passCount++; Write-Host "     ✅ $Msg" -ForegroundColor Green }
function Write-Warn    { param([string]$Msg) $script:warnCount++; Write-Host "     ⚠️  $Msg" -ForegroundColor Yellow }
function Write-Fail    { param([string]$Msg) $script:failCount++; Write-Host "     ❌ $Msg" -ForegroundColor Red }
function Write-SkipMsg { param([string]$Msg) $script:skipCount++; Write-Host "     ⏭️  $Msg" -ForegroundColor DarkGray }
function Write-Detail  { param([string]$Msg) Write-Host "        $Msg" -ForegroundColor Gray }
function Write-Link    { param([string]$Label, [string]$Url) Write-Host "        📖 $Label" -ForegroundColor DarkCyan; Write-Host "           $Url" -ForegroundColor DarkGray }

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "  ┌──────────────────────────────────────────────────────────────" -ForegroundColor White
    Write-Host "  │ $Title" -ForegroundColor White
    Write-Host "  └──────────────────────────────────────────────────────────────" -ForegroundColor White
}

# ── Banner ───────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  AVD Diagnostics — Fabric Networking Lab                    ║" -ForegroundColor Cyan
Write-Host "╠══════════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
Write-Host "║  Resource Group : $ResourceGroup" -ForegroundColor Cyan
Write-Host "║  Prefix         : $Prefix" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# ── Pre-flight ───────────────────────────────────────────────────────────────────

Write-Section "Pre-flight"

Write-Check "Verifying Azure CLI session..."
$account = az account show -o json 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Fail "Not logged in to Azure CLI. Run 'az login' first."
    exit 1
}
Write-Pass "Signed in as $($account.user.name) (subscription: $($account.name))"

Write-Check "Verifying resource group '$ResourceGroup' exists..."
$rgExists = az group show --name $ResourceGroup -o json 2>$null | ConvertFrom-Json
if (-not $rgExists) {
    Write-Fail "Resource group '$ResourceGroup' not found. Run infra_deploy.ps1 first."
    exit 1
}
Write-Pass "Resource group exists in $($rgExists.location)."

# ══════════════════════════════════════════════════════════════════════════════════
#  1. HOST POOLS
# ══════════════════════════════════════════════════════════════════════════════════

Write-Section "1. Host Pools"

$hostPoolNames = @("$Prefix-hp-a", "$Prefix-hp-b")
$hostPools = @{}

foreach ($hpName in $hostPoolNames) {
    Write-Check "Host pool '$hpName'..."
    $hp = az desktopvirtualization hostpool show `
        --name $hpName --resource-group $ResourceGroup -o json 2>$null | ConvertFrom-Json

    if (-not $hp) {
        Write-Fail "Host pool '$hpName' not found."
        continue
    }

    $hostPools[$hpName] = $hp
    Write-Pass "Found. Type=$($hp.hostPoolType), LoadBalancer=$($hp.loadBalancerType)"

    if ($hp.hostPoolType -ne 'Personal') {
        Write-Warn "Expected 'Personal' host pool type, got '$($hp.hostPoolType)'."
    }

    # Registration token validity
    if ($hp.PSObject.Properties['registrationInfo'] -and $hp.registrationInfo -and $hp.registrationInfo.expirationTime) {
        $expiry = [DateTime]::Parse($hp.registrationInfo.expirationTime)
        if ($expiry -lt (Get-Date)) {
            Write-Warn "Registration token expired at $($hp.registrationInfo.expirationTime). New session hosts cannot register."
            Write-Detail "Re-run infra_deploy.ps1 (without -SkipSessionHosts) to generate a fresh token."
        } else {
            Write-Pass "Registration token valid until $($hp.registrationInfo.expirationTime)."
        }
    } else {
        Write-Detail "No registration token set (normal after initial deployment)."
    }

    Write-Link "Host pool overview" "https://learn.microsoft.com/azure/virtual-desktop/terminology#host-pools"
}

# ══════════════════════════════════════════════════════════════════════════════════
#  2. APPLICATION GROUPS & WORKSPACES
# ══════════════════════════════════════════════════════════════════════════════════

Write-Section "2. Application Groups & Workspaces"

foreach ($hpName in $hostPoolNames) {
    $dagName = "$hpName-dag"
    $wsName  = "$hpName-ws"

    Write-Check "Application group '$dagName'..."
    $ag = az desktopvirtualization applicationgroup show `
        --name $dagName --resource-group $ResourceGroup -o json 2>$null | ConvertFrom-Json

    if (-not $ag) {
        Write-Fail "App group '$dagName' not found."
    } else {
        Write-Pass "Found. Type=$($ag.applicationGroupType)"

        if ($ag.hostPoolArmPath -notmatch $hpName) {
            Write-Fail "App group is linked to unexpected host pool: $($ag.hostPoolArmPath)"
        } else {
            Write-Pass "Correctly linked to host pool '$hpName'."
        }
    }

    Write-Check "Workspace '$wsName'..."
    $ws = az desktopvirtualization workspace show `
        --name $wsName --resource-group $ResourceGroup -o json 2>$null | ConvertFrom-Json

    if (-not $ws) {
        Write-Fail "Workspace '$wsName' not found."
    } else {
        $refCount = ($ws.applicationGroupReferences | Measure-Object).Count
        if ($refCount -eq 0) {
            Write-Fail "Workspace has no application group references — desktops won't appear in clients."
        } else {
            $dagLinked = $ws.applicationGroupReferences | Where-Object { $_ -match $dagName }
            if ($dagLinked) {
                Write-Pass "Workspace references app group '$dagName' ($refCount ref(s))."
            } else {
                Write-Warn "Workspace does not reference '$dagName'. Referenced: $($ws.applicationGroupReferences -join ', ')"
            }
        }
    }

    Write-Link "Application groups" "https://learn.microsoft.com/azure/virtual-desktop/terminology#application-groups"
    Write-Link "Workspaces" "https://learn.microsoft.com/azure/virtual-desktop/terminology#workspaces"
}

# ══════════════════════════════════════════════════════════════════════════════════
#  3. SESSION HOST VMs
# ══════════════════════════════════════════════════════════════════════════════════

Write-Section "3. Session Host VMs"

$vmNames = @("$Prefix-vm-a", "$Prefix-vm-b")
$vmFound = @{}

foreach ($vmName in $vmNames) {
    Write-Check "VM '$vmName'..."
    $vm = az vm show --resource-group $ResourceGroup --name $vmName `
        --show-details -o json 2>$null | ConvertFrom-Json

    if (-not $vm) {
        Write-Fail "VM '$vmName' not found. Deploy with: .\infra_deploy.ps1"
        continue
    }
    $vmFound[$vmName] = $vm

    $powerState = $vm.powerState
    if ($powerState -eq 'VM running') {
        Write-Pass "Running. Size=$($vm.hardwareProfile.vmSize)"
    } elseif ($powerState -match 'deallocated') {
        Write-Warn "VM is deallocated. Start with: .\lab_start.ps1"
    } else {
        Write-Warn "Unexpected power state: $powerState"
    }

    # Entra ID join extension
    Write-Check "  Entra ID join extension (AADLoginForWindows)..."
    $aadExt = az vm extension show --resource-group $ResourceGroup --vm-name $vmName `
        --name 'AADLoginForWindows' -o json 2>$null | ConvertFrom-Json

    if (-not $aadExt) {
        Write-Fail "AADLoginForWindows extension not found on $vmName."
        Write-Link "Entra ID join for AVD" "https://learn.microsoft.com/azure/virtual-desktop/azure-ad-joined-session-hosts"
    } else {
        if ($aadExt.provisioningState -eq 'Succeeded') {
            Write-Pass "Extension provisioned successfully."
        } else {
            Write-Fail "Extension state: $($aadExt.provisioningState)"
            if ($aadExt.instanceView -and $aadExt.instanceView.statuses) {
                foreach ($s in $aadExt.instanceView.statuses) {
                    Write-Detail "$($s.code): $($s.message)"
                }
            }
        }
    }

    # DSC extension (AVD agent registration)
    Write-Check "  DSC extension (AVD agent registration)..."
    $dscExt = az vm extension show --resource-group $ResourceGroup --vm-name $vmName `
        --name 'DSC' -o json 2>$null | ConvertFrom-Json

    if (-not $dscExt) {
        Write-Fail "DSC extension not found on $vmName. The VM is not registered as a session host."
        Write-Link "Troubleshoot DSC" "https://aka.ms/VMExtensionDSCWindowsTroubleshoot"
    } else {
        if ($dscExt.provisioningState -eq 'Succeeded') {
            Write-Pass "DSC extension provisioned successfully."
        } else {
            Write-Fail "DSC extension state: $($dscExt.provisioningState)"
            if ($dscExt.instanceView -and $dscExt.instanceView.statuses) {
                foreach ($s in $dscExt.instanceView.statuses) {
                    Write-Detail "$($s.code): $($s.message)"
                }
            }
            Write-Link "Troubleshoot DSC" "https://aka.ms/VMExtensionDSCWindowsTroubleshoot"
        }
    }

    Write-Link "Session host VMs" "https://learn.microsoft.com/azure/virtual-desktop/terminology#session-host-virtual-machines"
}

# ══════════════════════════════════════════════════════════════════════════════════
#  4. SESSION HOST REGISTRATION IN POOLS
# ══════════════════════════════════════════════════════════════════════════════════

Write-Section "4. Session Host Registration"

foreach ($hpName in $hostPoolNames) {
    Write-Check "Session hosts registered in '$hpName'..."
    $sessionHosts = az desktopvirtualization hostpool show `
        --name $hpName --resource-group $ResourceGroup -o json 2>$null | ConvertFrom-Json

    $shList = az rest --method GET `
        --url "https://management.azure.com/subscriptions/$($account.id)/resourceGroups/$ResourceGroup/providers/Microsoft.DesktopVirtualization/hostPools/$hpName/sessionHosts?api-version=2024-04-03" `
        -o json 2>$null | ConvertFrom-Json

    $hosts = $shList.value
    if (-not $hosts -or $hosts.Count -eq 0) {
        Write-Fail "No session hosts registered in '$hpName'."
        Write-Detail "VMs must have the DSC extension successfully provisioned to register."
    } else {
        foreach ($sh in $hosts) {
            $shName = ($sh.name -split '/')[1]
            $status = $sh.properties.status
            $updateState = $sh.properties.updateState
            $assigned = $sh.properties.assignedUser

            if ($status -eq 'Available') {
                Write-Pass "$shName — Status: Available, UpdateState: $updateState"
            } elseif ($status -eq 'Unavailable') {
                Write-Warn "$shName — Status: Unavailable (VM may be stopped or agent not responding)"
            } else {
                Write-Warn "$shName — Status: $status"
            }
            if ($assigned) {
                Write-Detail "Assigned to: $assigned"
            } else {
                Write-Detail "Not yet assigned to a user (will auto-assign on first connection)."
            }
        }
    }

    Write-Link "Session host statuses" "https://learn.microsoft.com/azure/virtual-desktop/troubleshoot-vm-configuration"
}

# ══════════════════════════════════════════════════════════════════════════════════
#  5. NETWORKING
# ══════════════════════════════════════════════════════════════════════════════════

Write-Section "5. Networking"

$vnetNames = @("$Prefix-vnet-a", "$Prefix-vnet-b")

foreach ($vnetName in $vnetNames) {
    Write-Check "VNet '$vnetName' — subnets and NAT gateway..."
    $vnet = az network vnet show --resource-group $ResourceGroup --name $vnetName -o json 2>$null | ConvertFrom-Json

    if (-not $vnet) {
        Write-Fail "VNet '$vnetName' not found."
        continue
    }

    Write-Pass "Address space: $($vnet.addressSpace.addressPrefixes -join ', ')"

    foreach ($subnet in $vnet.subnets) {
        $snetName = $subnet.name
        $natGw = $subnet.natGateway

        if ($snetName -eq 'snet-avd') {
            if ($natGw -and $natGw.id) {
                $natName = ($natGw.id -split '/')[-1]
                Write-Pass "snet-avd ($($subnet.addressPrefix)) — NAT gateway: $natName"
            } else {
                Write-Fail "snet-avd ($($subnet.addressPrefix)) has NO NAT gateway."
                Write-Detail "VMs in this subnet cannot reach the internet for DSC agent download."
                Write-Detail "Fix: re-run infra_deploy.ps1 to add the NAT gateway."
                Write-Link "Default outbound access retirement" "https://learn.microsoft.com/azure/virtual-network/ip-services/default-outbound-access"
                Write-Link "NAT gateway for AVD" "https://learn.microsoft.com/azure/nat-gateway/nat-overview"
            }
        } elseif ($snetName -eq 'snet-pe') {
            $pePolicies = $subnet.privateEndpointNetworkPolicies
            if ($pePolicies -eq 'Disabled') {
                Write-Pass "snet-pe ($($subnet.addressPrefix)) — PE network policies disabled ✓"
            } else {
                Write-Warn "snet-pe — privateEndpointNetworkPolicies is '$pePolicies' (expected 'Disabled')."
                Write-Link "PE network policies" "https://learn.microsoft.com/azure/private-link/disable-private-endpoint-network-policy"
            }
        } else {
            Write-Detail "Subnet '$snetName' ($($subnet.addressPrefix))"
        }
    }
}

# ══════════════════════════════════════════════════════════════════════════════════
#  6. RBAC ROLE ASSIGNMENTS
# ══════════════════════════════════════════════════════════════════════════════════

Write-Section "6. RBAC Role Assignments"

Write-Check "Discovering current user..."
$userId = az ad signed-in-user show --query id -o tsv --only-show-errors 2>$null
$userUpn = az ad signed-in-user show --query userPrincipalName -o tsv --only-show-errors 2>$null

if (-not $userId) {
    Write-Warn "Could not determine current user. Skipping RBAC checks."
} else {
    Write-Detail "Checking roles for: $userUpn ($userId)"

    # Virtual Machine User Login on RG
    Write-Check "'Virtual Machine User Login' on resource group..."
    $vmLoginRole = az role assignment list `
        --assignee $userId `
        --role "Virtual Machine User Login" `
        --resource-group $ResourceGroup `
        -o json --only-show-errors 2>$null | ConvertFrom-Json

    if ($vmLoginRole -and $vmLoginRole.Count -gt 0) {
        Write-Pass "Role assigned. User can sign in to Entra ID-joined VMs."
    } else {
        Write-Fail "Role NOT assigned. User cannot log in to session host VMs."
        Write-Detail "Fix: az role assignment create --assignee $userId --role 'Virtual Machine User Login' --resource-group $ResourceGroup"
        Write-Link "VM login RBAC" "https://learn.microsoft.com/azure/virtual-desktop/azure-ad-joined-session-hosts#assign-user-access-to-host-pools"
    }

    # Desktop Virtualization User on each app group
    foreach ($hpName in $hostPoolNames) {
        $dagName = "$hpName-dag"
        Write-Check "'Desktop Virtualization User' on app group '$dagName'..."

        $agId = az desktopvirtualization applicationgroup show `
            --name $dagName --resource-group $ResourceGroup `
            --query id -o tsv --only-show-errors 2>$null

        if (-not $agId) {
            Write-SkipMsg "App group '$dagName' not found — cannot check role."
            continue
        }

        $dvuRole = az role assignment list `
            --assignee $userId `
            --role "Desktop Virtualization User" `
            --scope $agId `
            -o json --only-show-errors 2>$null | ConvertFrom-Json

        if ($dvuRole -and $dvuRole.Count -gt 0) {
            Write-Pass "Role assigned. Desktop will appear in clients."
        } else {
            Write-Fail "Role NOT assigned. Desktop for '$dagName' will NOT appear in clients."
            Write-Detail "Fix: az role assignment create --assignee $userId --role 'Desktop Virtualization User' --scope '$agId'"
            Write-Link "Assign users to app groups" "https://learn.microsoft.com/azure/virtual-desktop/assign-users-to-host-pool"
        }
    }
}

# ══════════════════════════════════════════════════════════════════════════════════
#  7. PRIVATE DNS ZONES (informational)
# ══════════════════════════════════════════════════════════════════════════════════

Write-Section "7. Private DNS Zones (informational)"

Write-Check "Listing private DNS zones in resource group..."
$dnsZones = az network private-dns zone list --resource-group $ResourceGroup -o json 2>$null | ConvertFrom-Json

if (-not $dnsZones -or $dnsZones.Count -eq 0) {
    Write-Detail "No private DNS zones found (expected if Fabric Private Link not deployed)."
} else {
    foreach ($zone in $dnsZones) {
        Write-Detail "Zone: $($zone.name) ($($zone.numberOfRecordSets) record sets)"

        $links = az network private-dns link vnet list `
            --resource-group $ResourceGroup --zone-name $zone.name `
            -o json 2>$null | ConvertFrom-Json

        $linkCount = ($links | Measure-Object).Count
        if ($linkCount -eq 0) {
            Write-Warn "  Zone '$($zone.name)' has no VNet links — DNS resolution won't work from VNets."
        } else {
            foreach ($lnk in $links) {
                Write-Detail "  Linked to: $(($lnk.virtualNetwork.id -split '/')[-1]) (registration=$($lnk.registrationEnabled))"
            }
        }
    }
    Write-Link "Private DNS for PE" "https://learn.microsoft.com/azure/private-link/private-endpoint-dns"
}

# ══════════════════════════════════════════════════════════════════════════════════
#  SUMMARY
# ══════════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor White
Write-Host "║  Diagnostics Summary                                        ║" -ForegroundColor White
Write-Host "╠══════════════════════════════════════════════════════════════╣" -ForegroundColor White
Write-Host "║  ✅ Passed  : $script:passCount" -ForegroundColor Green
Write-Host "║  ⚠️  Warnings: $script:warnCount" -ForegroundColor Yellow
Write-Host "║  ❌ Failed  : $script:failCount" -ForegroundColor Red
if ($script:skipCount -gt 0) {
    Write-Host "║  ⏭️  Skipped : $script:skipCount" -ForegroundColor DarkGray
}
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor White
Write-Host ""

if ($script:failCount -eq 0 -and $script:warnCount -eq 0) {
    Write-Host "  🎉 All checks passed! Your AVD environment looks healthy." -ForegroundColor Green
} elseif ($script:failCount -eq 0) {
    Write-Host "  👍 No critical issues. Review the warnings above." -ForegroundColor Yellow
} else {
    Write-Host "  🔧 $($script:failCount) issue(s) need attention. See details above." -ForegroundColor Red
}

Write-Host ""
Write-Host "  📖 General AVD troubleshooting:" -ForegroundColor DarkCyan
Write-Host "     https://learn.microsoft.com/azure/virtual-desktop/troubleshoot-set-up-overview" -ForegroundColor DarkGray
Write-Host ""
