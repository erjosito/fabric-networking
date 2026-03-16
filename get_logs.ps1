<#
.SYNOPSIS
    Runs predefined KQL queries against a Log Analytics Workspace to troubleshoot
    Microsoft Fabric network security scenarios.

.DESCRIPTION
    Provides a library of curated KQL queries covering:
      - Network Security Perimeter (NSP) access logs
      - Azure Storage (Blob) diagnostic logs
      - Azure SQL Database audit, connectivity, and performance logs
      - VNet Flow Logs (NTA and legacy NSG)
      - Private Endpoint connection events
      - DNS resolution logs
      - Azure Firewall network and application rules
      - Private Link Service events
      - Azure Activity Log (control-plane networking changes)

    Queries are tailored for resources deployed by this repository: VNets,
    Storage Accounts, Azure SQL, Private Endpoints, NSP, and VNet Flow Logs.

.PARAMETER WorkspaceId
    The Log Analytics Workspace ID (GUID). If omitted the script attempts to
    discover it from the resource group using the naming convention {Prefix}-log.

.PARAMETER Query
    Name of the predefined query to run. Use -ListQueries to see all available
    names. Use "all" to run every query sequentially.

.PARAMETER Timespan
    Time range in ISO 8601 duration format.
    Examples: PT1H (1 hour), PT6H (6 hours), P1D (1 day), P7D (7 days).
    Default: P1D

.PARAMETER Top
    Limit the number of rows returned per query. Default: 100.
    Set to 0 to return all rows.

.PARAMETER ResourceFilter
    Optional. Filters results to rows containing this string (resource name,
    IP address, FQDN, etc.).

.PARAMETER ResourceGroup
    Azure resource group name. Used for auto-discovery of the workspace ID.
    Default: fabricnetworking

.PARAMETER Prefix
    Naming prefix used during deployment. Used for auto-discovery.
    Default: fabnet

.PARAMETER ListQueries
    List all available predefined queries with descriptions and exit.

.PARAMETER ShowKQL
    Print the raw KQL query text instead of executing it (useful for pasting
    into the Azure Portal).

.EXAMPLE
    .\get_logs.ps1 -Query nsp-access -Timespan PT6H

.EXAMPLE
    .\get_logs.ps1 -Query storage-blocked -Timespan P1D -ResourceFilter samplestgmauser

.EXAMPLE
    .\get_logs.ps1 -ListQueries

.EXAMPLE
    .\get_logs.ps1 -Query vnet-flow-denied -ShowKQL

.EXAMPLE
    .\get_logs.ps1 -Query all -Timespan PT1H -Top 20
#>

[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(ParameterSetName = 'Run')]
    [string]$WorkspaceId,

    [Parameter(Mandatory, ParameterSetName = 'Run')]
    [Parameter(Mandatory, ParameterSetName = 'Show')]
    [string]$Query,

    [Parameter(ParameterSetName = 'Run')]
    [Parameter(ParameterSetName = 'Show')]
    [ValidatePattern('^P(?:\d+D)?(?:T(?:\d+H)?(?:\d+M)?)?$')]
    [string]$Timespan = 'P1D',

    [Parameter(ParameterSetName = 'Run')]
    [Parameter(ParameterSetName = 'Show')]
    [int]$Top = 100,

    [Parameter(ParameterSetName = 'Run')]
    [string]$ResourceFilter,

    [Parameter(ParameterSetName = 'Run')]
    [string]$ResourceGroup = 'fabricnetworking',

    [Parameter(ParameterSetName = 'Run')]
    [string]$Prefix = 'fabnet',

    [Parameter(Mandatory, ParameterSetName = 'List')]
    [switch]$ListQueries,

    [Parameter(Mandatory, ParameterSetName = 'Show')]
    [switch]$ShowKQL
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ═══════════════════════════════════════════════════════════════════════════════
#  Query Definitions
# ═══════════════════════════════════════════════════════════════════════════════

$queries = [ordered]@{}


# -- NETWORK SECURITY PERIMETER ──────────────────────────────────

$queries["nsp-access"] = @{
    Category    = 'Network Security Perimeter'
    Description = 'All NSP access log entries — inbound and outbound with action'
    KQL         = 'NSPAccessLogs
| project TimeGenerated, ResourceId, Direction, AccessRuleApplied,
          SourceAddress, SourcePort, DestinationAddress, DestinationPort,
          Protocol, Action, Profile, MatchedRule
| sort by TimeGenerated desc'
}

$queries["nsp-denied"] = @{
    Category    = 'Network Security Perimeter'
    Description = 'NSP requests that were DENIED — misconfigured rules or unexpected traffic'
    KQL         = 'NSPAccessLogs
| where Action has_any ("Deny", "denied")
| project TimeGenerated, ResourceId, Direction,
          SourceAddress, DestinationAddress, DestinationPort,
          Protocol, Action, MatchedRule, Profile
| sort by TimeGenerated desc'
}

$queries["nsp-by-resource"] = @{
    Category    = 'Network Security Perimeter'
    Description = 'NSP allow/deny counts per resource per hour'
    KQL         = 'NSPAccessLogs
| summarize AllowCount = countif(Action has_any ("Allow", "allowed")),
            DenyCount  = countif(Action has_any ("Deny", "denied"))
  by ResourceId, Direction, bin(TimeGenerated, 1h)
| sort by TimeGenerated desc'
}

$queries["nsp-learning"] = @{
    Category    = 'Network Security Perimeter'
    Description = 'NSP Learning-mode events — traffic that WOULD be denied in enforced mode'
    KQL         = 'NSPAccessLogs
| where Profile has "Learning" or Profile has "learning"
| project TimeGenerated, ResourceId, Direction,
          SourceAddress, DestinationAddress, DestinationPort,
          Protocol, Action, MatchedRule, Profile
| sort by TimeGenerated desc'
}


# -- AZURE STORAGE ───────────────────────────────────────────────

$queries["storage-all"] = @{
    Category    = 'Azure Storage'
    Description = 'All Blob Storage operations — caller IP, auth type, status'
    KQL         = 'StorageBlobLogs
| project TimeGenerated, AccountName, OperationName, StatusCode, StatusText,
          CallerIpAddress, AuthenticationType, Uri, UserAgentHeader,
          TlsVersion, ServerLatencyMs
| sort by TimeGenerated desc'
}

$queries["storage-blocked"] = @{
    Category    = 'Azure Storage'
    Description = 'Storage requests DENIED (403) — firewall, network rules, or auth failures'
    KQL         = 'StorageBlobLogs
| where StatusCode == 403
    or StatusText has_any ("AuthorizationPermissionMismatch",
                           "AuthorizationFailure",
                           "NetworkRuleBlockedByDeny")
| project TimeGenerated, AccountName, OperationName, StatusCode, StatusText,
          CallerIpAddress, AuthenticationType, Uri, UserAgentHeader
| sort by TimeGenerated desc'
}

$queries["storage-private-vs-public"] = @{
    Category    = 'Azure Storage'
    Description = 'Storage traffic split: private-IP callers vs public-IP callers'
    KQL         = 'StorageBlobLogs
| extend AccessPath = case(
    CallerIpAddress startswith "10." or CallerIpAddress startswith "172."
        or CallerIpAddress startswith "192.168.", "PrivateEndpoint",
    CallerIpAddress == "", "ServiceInternal",
    "PublicInternet")
| summarize RequestCount = count(),
            AvgLatencyMs = round(avg(ServerLatencyMs), 1),
            Errors       = countif(StatusCode >= 400)
  by AccountName, AccessPath, AuthenticationType, bin(TimeGenerated, 1h)
| sort by TimeGenerated desc'
}

$queries["storage-operations"] = @{
    Category    = 'Azure Storage'
    Description = 'Storage operation summary — error rates, latencies (P95)'
    KQL         = 'StorageBlobLogs
| summarize TotalRequests  = count(),
            FailedRequests = countif(StatusCode >= 400),
            AvgLatencyMs   = round(avg(ServerLatencyMs), 1),
            P95LatencyMs   = round(percentile(ServerLatencyMs, 95), 1)
  by AccountName, OperationName, bin(TimeGenerated, 1h)
| order by FailedRequests desc, TotalRequests desc'
}


# -- AZURE SQL DATABASE ──────────────────────────────────────────

$queries["sql-connectivity"] = @{
    Category    = 'Azure SQL Database'
    Description = 'SQL connection events — successes and failures with client IP'
    KQL         = 'AzureDiagnostics
| where ResourceProvider == "MICROSOFT.SQL"
| where Category in ("SQLSecurityAuditEvents", "ConnectionEvents")
| project TimeGenerated, Resource, ResourceGroup, Category,
          event_class_s, action_name_s, succeeded_s,
          client_ip_s, application_name_s, server_principal_name_s,
          database_name_s, statement_s
| sort by TimeGenerated desc'
}

$queries["sql-failed"] = @{
    Category    = 'Azure SQL Database'
    Description = 'FAILED SQL connections — auth errors, network blocks, timeouts'
    KQL         = 'AzureDiagnostics
| where ResourceProvider == "MICROSOFT.SQL"
| where Category == "SQLSecurityAuditEvents"
| where succeeded_s == "false" or action_name_s has_any ("FAILED", "BLOCK")
| project TimeGenerated, Resource, database_name_s,
          action_name_s, succeeded_s, client_ip_s,
          application_name_s, server_principal_name_s,
          additional_information_s, statement_s
| sort by TimeGenerated desc'
}

$queries["sql-firewall"] = @{
    Category    = 'Azure SQL Database'
    Description = 'SQL firewall events — connections blocked by server/database firewall'
    KQL         = 'AzureDiagnostics
| where ResourceProvider == "MICROSOFT.SQL"
| where action_name_s has_any ("FIREWALL", "BLOCK", "DENY")
    or (Category == "SQLSecurityAuditEvents" and statement_s has "firewall")
| project TimeGenerated, Resource, database_name_s,
          action_name_s, client_ip_s, application_name_s,
          additional_information_s
| sort by TimeGenerated desc'
}

$queries["sql-errors"] = @{
    Category    = 'Azure SQL Database'
    Description = 'SQL diagnostic errors — query failures, timeouts, deadlocks'
    KQL         = 'AzureDiagnostics
| where ResourceProvider == "MICROSOFT.SQL"
| where Category in ("Errors", "Timeouts", "Blocks", "Deadlocks")
| project TimeGenerated, Resource, Category, database_name_s,
          error_number_d, error_severity_d, error_state_d, error_message_s,
          query_hash_s, query_plan_hash_s
| sort by TimeGenerated desc'
}

$queries["sql-audit-summary"] = @{
    Category    = 'Azure SQL Database'
    Description = 'SQL audit summary — action counts split by success/failure per hour'
    KQL         = 'AzureDiagnostics
| where ResourceProvider == "MICROSOFT.SQL"
| where Category == "SQLSecurityAuditEvents"
| summarize SuccessCount = countif(succeeded_s == "true"),
            FailureCount = countif(succeeded_s == "false")
  by Resource, action_name_s, bin(TimeGenerated, 1h)
| order by FailureCount desc, TimeGenerated desc'
}


# -- VNET FLOW LOGS ──────────────────────────────────────────────

$queries["vnet-flow-all"] = @{
    Category    = 'VNet Flow Logs'
    Description = 'All VNet flow records — source, destination, ports, action'
    KQL         = 'NTANetAnalytics
| project TimeGenerated, FlowDirection, SrcIp, DestIp,
          SrcPort, DestPort, L4Protocol, FlowStatus,
          NSGRule, Subnet, VNet, AclGroup
| sort by TimeGenerated desc'
}

$queries["vnet-flow-denied"] = @{
    Category    = 'VNet Flow Logs'
    Description = 'DENIED VNet flows — traffic blocked by NSG rules'
    KQL         = 'NTANetAnalytics
| where FlowStatus in ("D", "Denied")
| project TimeGenerated, FlowDirection, SrcIp, DestIp,
          SrcPort, DestPort, L4Protocol, FlowStatus,
          NSGRule, Subnet, VNet
| sort by TimeGenerated desc'
}

$queries["vnet-flow-sql"] = @{
    Category    = 'VNet Flow Logs'
    Description = 'Flows targeting SQL port 1433 — verify private endpoint connectivity'
    KQL         = 'NTANetAnalytics
| where DestPort == 1433
| project TimeGenerated, FlowDirection, SrcIp, DestIp,
          SrcPort, DestPort, L4Protocol, FlowStatus,
          NSGRule, Subnet, VNet
| sort by TimeGenerated desc'
}

$queries["vnet-flow-storage"] = @{
    Category    = 'VNet Flow Logs'
    Description = 'Flows targeting port 443 — verify blob private endpoint traffic'
    KQL         = 'NTANetAnalytics
| where DestPort == 443
| project TimeGenerated, FlowDirection, SrcIp, DestIp,
          SrcPort, DestPort, L4Protocol, FlowStatus,
          NSGRule, Subnet, VNet
| sort by TimeGenerated desc'
}

$queries["vnet-flow-summary"] = @{
    Category    = 'VNet Flow Logs'
    Description = 'Flow summary per subnet — allowed/denied counts and bytes (hourly)'
    KQL         = 'NTANetAnalytics
| summarize AllowedFlows = countif(FlowStatus in ("A", "Allowed")),
            DeniedFlows  = countif(FlowStatus in ("D", "Denied")),
            TotalBytes   = sum(BytesSrcToDest + BytesDestToSrc)
  by Subnet, VNet, FlowDirection, bin(TimeGenerated, 1h)
| sort by DeniedFlows desc, TimeGenerated desc'
}

$queries["nsg-flow-legacy"] = @{
    Category    = 'VNet Flow Logs'
    Description = 'Legacy NSG flow logs (AzureNetworkAnalytics_CL) — use if NTANetAnalytics is empty'
    KQL         = 'AzureNetworkAnalytics_CL
| where SubType_s == "FlowLog"
| project TimeGenerated, FlowDirection_s, SrcIP_s, DestIP_s,
          SrcPort_d, DestPort_d, L4Protocol_s, FlowStatus_s,
          NSGRule_s, Subnet1_s, Subnet2_s
| sort by TimeGenerated desc'
}


# -- PRIVATE ENDPOINT ────────────────────────────────────────────

$queries["pe-connections"] = @{
    Category    = 'Private Endpoint'
    Description = 'Private endpoint and private link connection state changes'
    KQL         = 'AzureActivity
| where OperationNameValue has_any (
    "Microsoft.Network/privateEndpoints",
    "Microsoft.Network/privateLinkServices",
    "privateEndpointConnections")
| project TimeGenerated, OperationNameValue, ActivityStatusValue,
          ResourceGroup, Resource = _ResourceId,
          Caller, CallerIpAddress, Properties
| sort by TimeGenerated desc'
}

$queries["pe-dns"] = @{
    Category    = 'Private Endpoint'
    Description = 'Private DNS zone changes — A-record registrations for private endpoints'
    KQL         = 'AzureActivity
| where OperationNameValue has "Microsoft.Network/privateDnsZones"
| project TimeGenerated, OperationNameValue, ActivityStatusValue,
          ResourceGroup, Resource = _ResourceId, Caller, Properties
| sort by TimeGenerated desc'
}


# -- DNS ─────────────────────────────────────────────────────────

$queries["dns-queries"] = @{
    Category    = 'DNS'
    Description = 'DNS queries from Azure DNS Private Resolver or forwarders'
    KQL         = 'DnsEvents
| project TimeGenerated, Name, QueryType, IPAddresses, ClientIP, Result
| sort by TimeGenerated desc'
}

$queries["dns-fabric"] = @{
    Category    = 'DNS'
    Description = 'DNS lookups for Fabric, Power BI, Storage, and SQL FQDNs'
    KQL         = 'DnsEvents
| where Name has_any (
    "fabric.microsoft.com",
    "analysis.windows.net",
    "pbidedicated.windows.net",
    "powerquery.microsoft.com",
    "dfs.core.windows.net",
    "blob.core.windows.net",
    "database.windows.net")
| project TimeGenerated, Name, QueryType, IPAddresses, ClientIP, Result
| sort by TimeGenerated desc'
}

$queries["dns-failures"] = @{
    Category    = 'DNS'
    Description = 'DNS resolution failures — NXDOMAIN, SERVFAIL, REFUSED'
    KQL         = 'DnsEvents
| where Result has_any ("NXDOMAIN", "SERVFAIL", "REFUSED")
    or ResultCode in (2, 3, 5)
| project TimeGenerated, Name, QueryType, ClientIP, Result, ResultCode
| sort by TimeGenerated desc'
}


# -- AZURE FIREWALL ──────────────────────────────────────────────

$queries["fw-network"] = @{
    Category    = 'Azure Firewall'
    Description = 'Firewall network rule log — allowed and denied flows'
    KQL         = 'AZFWNetworkRule
| project TimeGenerated, Protocol, SourceIp, SourcePort,
          DestinationIp, DestinationPort, Action, Policy, RuleCollection, Rule
| sort by TimeGenerated desc'
}

$queries["fw-application"] = @{
    Category    = 'Azure Firewall'
    Description = 'Firewall application (FQDN) rule log — HTTP/S traffic'
    KQL         = 'AZFWApplicationRule
| project TimeGenerated, Protocol, SourceIp, Fqdn,
          TargetUrl, Action, Policy, RuleCollection, Rule
| sort by TimeGenerated desc'
}

$queries["fw-denied"] = @{
    Category    = 'Azure Firewall'
    Description = 'All Firewall DENIED traffic — network + application rules combined'
    KQL         = 'let denied_net = AZFWNetworkRule
    | where Action == "Deny"
    | project TimeGenerated, RuleType = "NetworkRule", Protocol,
              Source = SourceIp, Destination = DestinationIp,
              Port = tostring(DestinationPort), Action, Rule;
let denied_app = AZFWApplicationRule
    | where Action == "Deny"
    | project TimeGenerated, RuleType = "AppRule", Protocol,
              Source = SourceIp, Destination = Fqdn,
              Port = "", Action, Rule;
union denied_net, denied_app
| sort by TimeGenerated desc'
}

$queries["fw-fabric-fqdns"] = @{
    Category    = 'Azure Firewall'
    Description = 'Firewall hits for Fabric / Power BI / OneLake / Storage / SQL FQDNs'
    KQL         = 'AZFWApplicationRule
| where Fqdn has_any (
    "fabric.microsoft.com",
    "analysis.windows.net",
    "pbidedicated.windows.net",
    "onelake.dfs.fabric.microsoft.com",
    "blob.core.windows.net",
    "database.windows.net",
    "servicebus.windows.net")
| project TimeGenerated, SourceIp, Fqdn, TargetUrl,
          Action, Policy, RuleCollection, Rule
| sort by TimeGenerated desc'
}


# -- PRIVATE LINK SERVICE ────────────────────────────────────────

$queries["pls-events"] = @{
    Category    = 'Private Link Service'
    Description = 'Private Link Service connection events (Fabric tenant/workspace PLS)'
    KQL         = 'AzureActivity
| where OperationNameValue has_any (
    "Microsoft.Network/privateLinkServices",
    "Microsoft.PowerBI/privateLinkServicesForPowerBI",
    "Microsoft.Fabric/privateLinkServicesForFabric")
| project TimeGenerated, OperationNameValue, ActivityStatusValue,
          ResourceGroup, Resource = _ResourceId, Caller, Properties
| sort by TimeGenerated desc'
}


# -- DATA GATEWAY ────────────────────────────────────────────────

$queries["gateway-operations"] = @{
    Category    = 'Data Gateway'
    Description = 'VNet Data Gateway and on-premises gateway resource operations'
    KQL         = 'AzureActivity
| where OperationNameValue has_any (
    "Microsoft.Network/virtualNetworkGateways",
    "Microsoft.PowerBI/dataGateways",
    "Microsoft.Network/connections")
| project TimeGenerated, OperationNameValue, ActivityStatusValue,
          ResourceGroup, Resource = _ResourceId, Caller, Properties
| sort by TimeGenerated desc'
}


# -- ACTIVITY LOG ────────────────────────────────────────────────

$queries["activity-network"] = @{
    Category    = 'Activity Log'
    Description = 'Control-plane changes to networking resources (NSGs, VNets, PEs, DNS, NSP)'
    KQL         = 'AzureActivity
| where OperationNameValue has_any (
    "Microsoft.Network/networkSecurityGroups",
    "Microsoft.Network/virtualNetworks",
    "Microsoft.Network/privateEndpoints",
    "Microsoft.Network/privateDnsZones",
    "Microsoft.Network/privateLinkServices",
    "Microsoft.Network/networkSecurityPerimeters",
    "Microsoft.Network/natGateways")
| where ActivityStatusValue in ("Success", "Failed", "Start")
| project TimeGenerated, OperationNameValue, ActivityStatusValue,
          ResourceGroup, Resource = _ResourceId,
          Caller, CallerIpAddress
| sort by TimeGenerated desc'
}

$queries["activity-failures"] = @{
    Category    = 'Activity Log'
    Description = 'All FAILED ARM operations — deployment and configuration errors'
    KQL         = 'AzureActivity
| where ActivityStatusValue == "Failed"
| project TimeGenerated, OperationNameValue, ActivityStatusValue,
          ResourceGroup, Resource = _ResourceId,
          Caller, Properties
| sort by TimeGenerated desc'
}


# ═══════════════════════════════════════════════════════════════════════════════
#  Helpers
# ═══════════════════════════════════════════════════════════════════════════════

function Show-QueryList {
    $currentCategory = ""
    foreach ($key in $queries.Keys) {
        $q = $queries[$key]
        if ($q.Category -ne $currentCategory) {
            $currentCategory = $q.Category
            Write-Host ""
            Write-Host "  --- $currentCategory ---" -ForegroundColor Cyan
        }
        $padded = $key.PadRight(30)
        Write-Host "    $padded" -ForegroundColor Yellow -NoNewline
        Write-Host $q.Description
    }
    Write-Host ""
    Write-Host "  Tip: " -NoNewline
    Write-Host "-Query all" -ForegroundColor Yellow -NoNewline
    Write-Host " runs every query.  "  -NoNewline
    Write-Host "-ShowKQL" -ForegroundColor Yellow -NoNewline
    Write-Host " prints the KQL without executing."
    Write-Host ""
}

function Resolve-WorkspaceId {
    param([string]$RG, [string]$PrefixName)
    $logName = "$PrefixName-log"
    Write-Host "  Discovering Log Analytics Workspace '$logName' in resource group '$RG' ..." -ForegroundColor DarkGray
    $ws = az monitor log-analytics workspace show `
        --resource-group $RG `
        --workspace-name $logName `
        --query customerId -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $ws) {
        Write-Error "Could not find Log Analytics Workspace '$logName' in RG '$RG'. Provide -WorkspaceId explicitly."
        return $null
    }
    Write-Host "  Found workspace: $ws" -ForegroundColor DarkGray
    return $ws.Trim()
}

# ═══════════════════════════════════════════════════════════════════════════════
#  Main
# ═══════════════════════════════════════════════════════════════════════════════

if ($ListQueries) {
    Show-QueryList
    return
}

# Validate query name
if ($Query -ne 'all' -and -not $queries.Contains($Query)) {
    Write-Error "Unknown query: '$Query'. Use -ListQueries to see available queries."
    return
}

# Determine which queries to run
$queriesToRun = if ($Query -eq 'all') { $queries.Keys } else { @($Query) }

# ShowKQL mode — print and exit
if ($ShowKQL) {
    foreach ($qName in $queriesToRun) {
        $qDef = $queries[$qName]
        Write-Host ""
        Write-Host "// --- $qName : $($qDef.Description)" -ForegroundColor Cyan
        Write-Host $qDef.KQL
    }
    return
}

# Auto-discover workspace ID if not provided
if (-not $WorkspaceId) {
    $WorkspaceId = Resolve-WorkspaceId -RG $ResourceGroup -PrefixName $Prefix
    if (-not $WorkspaceId) { return }
}

# Ensure the Az.OperationalInsights module is available
if (-not (Get-Command Invoke-AzOperationalInsightsQuery -ErrorAction SilentlyContinue)) {
    Write-Error "The Az.OperationalInsights module is required. Install with: Install-Module Az.OperationalInsights -Scope CurrentUser"
    return
}

foreach ($qName in $queriesToRun) {
    $qDef = $queries[$qName]
    $kql  = $qDef.KQL

    # Append resource filter
    if ($ResourceFilter) {
        $kql += "`n| where tostring(pack_all()) contains '$ResourceFilter'"
    }

    # Append row limit
    if ($Top -gt 0) {
        $kql += "`n| take $Top"
    }

    Write-Host ""
    Write-Host "  +-- [$qName] $($qDef.Description)" -ForegroundColor Cyan
    Write-Host "  |  Category : $($qDef.Category)"
    Write-Host "  |  Timespan : $Timespan    Top: $(if ($Top -gt 0) { $Top } else { 'unlimited' })"
    if ($ResourceFilter) {
        Write-Host "  |  Filter   : $ResourceFilter" -ForegroundColor Yellow
    }
    Write-Host "  +----------------------------------------------" -ForegroundColor Cyan

    try {
        $result = Invoke-AzOperationalInsightsQuery `
            -WorkspaceId $WorkspaceId `
            -Query $kql `
            -Timespan $Timespan `
            -ErrorAction Stop

        if ($result.Results -and $result.Results.Count -gt 0) {
            Write-Host "    $($result.Results.Count) row(s) returned" -ForegroundColor Green
            $result.Results | Format-Table -AutoSize -Wrap
        }
        else {
            Write-Host "    No results for this time range." -ForegroundColor DarkGray
        }
    }
    catch {
        $msg = $_.Exception.Message
        if ($msg -match 'BadArgumentError|SemanticError|is not recognized|not found') {
            Write-Host '    Table not available - diagnostics may not be configured for this resource.' -ForegroundColor DarkYellow
            Write-Host "    $msg" -ForegroundColor DarkGray
        }
        else {
            Write-Host "    Error: $msg" -ForegroundColor Red
        }
    }
}

Write-Host ''
Write-Host '  Done.' -ForegroundColor Green
