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

.PARAMETER TimeRange
    Time range in ISO 8601 duration format. Default: P1D
    Examples:
      PT30M  — last 30 minutes
      PT1H   — last 1 hour
      PT6H   — last 6 hours
      P1D    — last 1 day
      P3D    — last 3 days
      P7D    — last 7 days
      P30D   — last 30 days

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
    .\get_logs.ps1 -Query nsp-access -TimeRange PT6H

.EXAMPLE
    .\get_logs.ps1 -Query storage-blocked -TimeRange P1D -ResourceFilter samplestgmauser

.EXAMPLE
    .\get_logs.ps1 -ListQueries

.EXAMPLE
    .\get_logs.ps1 -Query vnet-flow-denied -ShowKQL

.EXAMPLE
    .\get_logs.ps1 -Query all -TimeRange PT1H -Top 20
#>

[CmdletBinding(DefaultParameterSetName = 'List')]
param(
    [Parameter(ParameterSetName = 'Run')]
    [string]$WorkspaceId,

    [Parameter(Mandatory, ParameterSetName = 'Run')]
    [Parameter(Mandatory, ParameterSetName = 'Show')]
    [string]$Query,

    [Parameter(ParameterSetName = 'Run')]
    [Parameter(ParameterSetName = 'Show')]
    [ValidatePattern('^P(?:\d+D)?(?:T(?:\d+H)?(?:\d+M)?)?$')]
    [string]$TimeRange = 'P1D',

    [Parameter(ParameterSetName = 'Run')]
    [Parameter(ParameterSetName = 'Show')]
    [int]$Top = 100,

    [Parameter(ParameterSetName = 'Run')]
    [string]$ResourceFilter,

    [Parameter(ParameterSetName = 'Run')]
    [string]$ResourceGroup = 'fabricnetworking',

    [Parameter(ParameterSetName = 'Run')]
    [string]$Prefix = 'fabnet',

    [Parameter(ParameterSetName = 'List')]
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
| project TimeGenerated, ResultDirection, ResultAction,
          SourceIpAddress, OperationName, TrafficType, MatchedRule
| sort by TimeGenerated desc'
}

$queries["nsp-denied"] = @{
    Category    = 'Network Security Perimeter'
    Description = 'NSP requests that were DENIED — misconfigured rules or unexpected traffic'
    KQL         = 'NSPAccessLogs
| where ResultAction has_any ("Deny", "denied")
| project TimeGenerated, ResultDirection, ResultAction,
          SourceIpAddress, OperationName, TrafficType, MatchedRule
| sort by TimeGenerated desc'
}

$queries["nsp-by-resource"] = @{
    Category    = 'Network Security Perimeter'
    Description = 'NSP allow/deny counts per resource per hour'
    KQL         = 'NSPAccessLogs
| summarize AllowCount = countif(ResultAction has_any ("Allow", "allowed")),
            DenyCount  = countif(ResultAction has_any ("Deny", "denied"))
  by ServiceResourceId, ResultDirection, TrafficType, bin(TimeGenerated, 1h)
| sort by TimeGenerated desc'
}

$queries["nsp-learning"] = @{
    Category    = 'Network Security Perimeter'
    Description = 'NSP Learning-mode events — traffic that WOULD be denied in enforced mode'
    KQL         = 'NSPAccessLogs
| where Profile has "Learning" or Profile has "learning"
| project TimeGenerated, ResultDirection, ResultAction,
          SourceIpAddress, OperationName, TrafficType, MatchedRule
| sort by TimeGenerated desc'
}


# -- AZURE STORAGE ───────────────────────────────────────────────

$queries["storage-all"] = @{
    Category    = 'Azure Storage'
    Description = 'All Blob Storage operations — caller IP, auth type, status'
    KQL         = 'StorageBlobLogs
| project TimeGenerated, AccountName, OperationName,
          StatusCode, CallerIpAddress, AuthenticationType, ObjectKey
| sort by TimeGenerated desc'
}

$queries["storage-blocked"] = @{
    Category    = 'Azure Storage'
    Description = 'Storage requests DENIED (403) — firewall, network rules, or auth failures'
    KQL         = 'StorageBlobLogs
| where toint(StatusCode) == 403
    or StatusText has_any ("AuthorizationPermissionMismatch",
                           "AuthorizationFailure",
                           "NetworkRuleBlockedByDeny")
| project TimeGenerated, AccountName, OperationName,
          StatusText, CallerIpAddress, RequesterUpn, ObjectKey
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
            AvgLatencyMs = round(avg(toreal(ServerLatencyMs)), 1),
            Errors       = countif(toint(StatusCode) >= 400)
  by AccountName, AccessPath, AuthenticationType, bin(TimeGenerated, 1h)
| sort by TimeGenerated desc'
}

$queries["storage-operations"] = @{
    Category    = 'Azure Storage'
    Description = 'Storage operation summary — error rates, latencies (P95)'
    KQL         = 'StorageBlobLogs
| summarize TotalRequests  = count(),
            FailedRequests = countif(toint(StatusCode) >= 400),
            AvgLatencyMs   = round(avg(toreal(ServerLatencyMs)), 1),
            P95LatencyMs   = round(percentile(toreal(ServerLatencyMs), 95), 1)
  by AccountName, OperationName, bin(TimeGenerated, 1h)
| order by FailedRequests desc, TotalRequests desc'
}


# -- AZURE SQL DATABASE ──────────────────────────────────────────

$queries["sql-connectivity"] = @{
    Category    = 'Azure SQL Database'
    Description = 'SQL connection events — successes and failures with client IP'
    KQL         = 'AzureDiagnostics
| where ResourceProvider contains "SQL"
| where Category in ("SQLSecurityAuditEvents", "ConnectionEvents")
| project TimeGenerated, DatabaseName_s, Category,
          OperationName, ResultType, clientIP_s, Message
| sort by TimeGenerated desc'
}

$queries["sql-failed"] = @{
    Category    = 'Azure SQL Database'
    Description = 'FAILED SQL connections — auth errors, network blocks, timeouts'
    KQL         = 'AzureDiagnostics
| where ResourceProvider contains "SQL"
| where Category == "SQLSecurityAuditEvents"
    or (Category == "Errors" and Severity >= 11)
| project TimeGenerated, DatabaseName_s, Category,
          OperationName, clientIP_s, error_number_d, Message
| sort by TimeGenerated desc'
}

$queries["sql-firewall"] = @{
    Category    = 'Azure SQL Database'
    Description = 'SQL firewall events — connections blocked by server/database firewall'
    KQL         = 'AzureDiagnostics
| where ResourceProvider contains "SQL"
| where Message has_any ("firewall", "Firewall", "blocked", "BLOCK", "DENY")
    or OperationName has_any ("FIREWALL", "BLOCK")
| project TimeGenerated, DatabaseName_s,
          OperationName, clientIP_s, Message
| sort by TimeGenerated desc'
}

$queries["sql-errors"] = @{
    Category    = 'Azure SQL Database'
    Description = 'SQL diagnostic errors — query failures, timeouts, deadlocks'
    KQL         = 'AzureDiagnostics
| where ResourceProvider contains "SQL"
| where Category in ("Errors", "Timeouts", "Blocks", "Deadlocks")
| project TimeGenerated, DatabaseName_s, Category,
          OperationName, error_number_d, Severity, Message
| sort by TimeGenerated desc'
}

$queries["sql-audit-summary"] = @{
    Category    = 'Azure SQL Database'
    Description = 'SQL audit summary — event counts by category and operation per hour'
    KQL         = 'AzureDiagnostics
| where ResourceProvider contains "SQL"
| summarize EventCount = count()
  by LogicalServerName_s, DatabaseName_s, Category, OperationName,
     bin(TimeGenerated, 1h)
| order by EventCount desc, TimeGenerated desc'
}


# -- VNET FLOW LOGS ──────────────────────────────────────────────

$queries["vnet-flow-all"] = @{
    Category    = 'VNet Flow Logs'
    Description = 'All VNet flow records with public IP enrichment'
    KQL         = 'let IpInfo = NTAIpDetails
    | project Ip, Location, PublicIpDetails;
NTANetAnalytics
| where SubType == "FlowLog"
| extend SrcIp = iff(isempty(SrcIp), tostring(split(split(SrcPublicIps, " ")[0], "|")[0]), SrcIp)
| extend DestIp = iff(isempty(DestIp), tostring(split(split(DestPublicIps, " ")[0], "|")[0]), DestIp)
| lookup kind=leftouter IpInfo on $left.DestIp==$right.Ip
| extend DestLocation = Location | project-away Location, PublicIpDetails
| project TimeGenerated, FlowStatus, L4Protocol,
          SrcIp, SrcSubnet, DestIp, DestPort, DestSubnet, DestLocation,
          BytesSrcToDest, BytesDestToSrc, NsgRule
| sort by TimeGenerated desc'
}

$queries["vnet-flow-denied"] = @{
    Category    = 'VNet Flow Logs'
    Description = 'Denied flows — blocked by NSG rules, with deny counters'
    KQL         = 'NTANetAnalytics
| where SubType == "FlowLog"
| where DeniedInFlows > 0 or DeniedOutFlows > 0
| extend SrcIp = iff(isempty(SrcIp), tostring(split(split(SrcPublicIps, " ")[0], "|")[0]), SrcIp)
| extend DestIp = iff(isempty(DestIp), tostring(split(split(DestPublicIps, " ")[0], "|")[0]), DestIp)
| summarize DeniedIn=sum(DeniedInFlows), DeniedOut=sum(DeniedOutFlows)
  by SrcIp, DestIp, DestPort, L4Protocol, AclRule, NsgRule
| extend TotalDenied = DeniedIn + DeniedOut
| sort by TotalDenied desc'
}

$queries["vnet-flow-top"] = @{
    Category    = 'VNet Flow Logs'
    Description = 'Top talkers by bytes — enriched with geolocation'
    KQL         = 'let IpInfo = NTAIpDetails
    | project Ip, Location, PublicIpDetails;
NTANetAnalytics
| where SubType == "FlowLog"
| extend SrcIp = iff(isempty(SrcIp), tostring(split(split(SrcPublicIps, " ")[0], "|")[0]), SrcIp)
| extend DestIp = iff(isempty(DestIp), tostring(split(split(DestPublicIps, " ")[0], "|")[0]), DestIp)
| lookup kind=leftouter IpInfo on $left.DestIp==$right.Ip
| extend DestLocation = Location | project-away Location, PublicIpDetails
| summarize FlowCount=count(),
            TotalBytes=sum(BytesSrcToDest + BytesDestToSrc)
  by SrcIp, DestIp, DestPort, L4Protocol, DestLocation
| top 50 by TotalBytes desc'
}

$queries["vnet-flow-protocols"] = @{
    Category    = 'VNet Flow Logs'
    Description = 'Traffic by protocol and port — volume and flow counts'
    KQL         = 'NTANetAnalytics
| where SubType == "FlowLog"
| summarize FlowCount=count(),
            TotalBytes=sum(BytesSrcToDest + BytesDestToSrc)
  by L4Protocol, DestPort
| order by TotalBytes desc'
}

$queries["vnet-flow-sql"] = @{
    Category    = 'VNet Flow Logs'
    Description = 'Flows targeting SQL port 1433 — verify private endpoint connectivity'
    KQL         = 'NTANetAnalytics
| where SubType == "FlowLog"
| where DestPort == 1433
| project TimeGenerated, FlowStatus, SrcIp, SrcSubnet,
          DestIp, DestPort, PrivateEndpointResourceId,
          BytesSrcToDest, BytesDestToSrc
| sort by TimeGenerated desc'
}

$queries["vnet-flow-storage"] = @{
    Category    = 'VNet Flow Logs'
    Description = 'Flows targeting port 443 — verify blob private endpoint traffic'
    KQL         = 'NTANetAnalytics
| where SubType == "FlowLog"
| where DestPort == 443
| project TimeGenerated, FlowStatus, SrcIp, SrcSubnet,
          DestIp, DestPort, PrivateEndpointResourceId,
          BytesSrcToDest, BytesDestToSrc
| sort by TimeGenerated desc'
}

$queries["vnet-flow-cross"] = @{
    Category    = 'VNet Flow Logs'
    Description = 'Cross-VNet traffic (VNet A 10.0.x ↔ VNet B 10.1.x)'
    KQL         = 'NTANetAnalytics
| where SubType == "FlowLog"
| where (SrcIp startswith "10.0." and DestIp startswith "10.1.")
     or (SrcIp startswith "10.1." and DestIp startswith "10.0.")
| summarize FlowCount=count(),
            BytesSent=sum(BytesSrcToDest),
            BytesRecv=sum(BytesDestToSrc)
  by SrcIp, DestIp, DestPort, L4Protocol
| sort by FlowCount desc'
}

$queries["vnet-flow-private"] = @{
    Category    = 'VNet Flow Logs'
    Description = 'Private-to-private flows — PE subnet traffic and internal routing'
    KQL         = 'NTANetAnalytics
| where SubType == "FlowLog"
| where isnotempty(SrcIp) and isnotempty(DestIp)
| where ipv4_is_private(SrcIp) and ipv4_is_private(DestIp)
| summarize FlowCount=count(),
            TotalBytes=sum(BytesSrcToDest + BytesDestToSrc)
  by SrcIp, SrcSubnet, DestIp, DestSubnet, DestPort, L4Protocol
| sort by TotalBytes desc'
}

$queries["vnet-flow-summary"] = @{
    Category    = 'VNet Flow Logs'
    Description = 'Flow summary per subnet — allowed/denied counts and bytes (hourly)'
    KQL         = 'NTANetAnalytics
| where SubType == "FlowLog"
| summarize AllowedFlows = sum(AllowedInFlows + AllowedOutFlows),
            DeniedFlows  = sum(DeniedInFlows + DeniedOutFlows),
            TotalBytes   = sum(BytesSrcToDest + BytesDestToSrc)
  by SrcSubnet, DestSubnet, FlowDirection, bin(TimeGenerated, 1h)
| sort by DeniedFlows desc, TimeGenerated desc'
}

$queries["nsg-flow-legacy"] = @{
    Category    = 'VNet Flow Logs'
    Description = 'Legacy NSG flow logs (AzureNetworkAnalytics_CL) — use if NTANetAnalytics is empty'
    KQL         = 'AzureNetworkAnalytics_CL
| where SubType_s == "FlowLog"
| project TimeGenerated, FlowDirection_s, FlowStatus_s, L4Protocol_s,
          SrcIP_s, SrcPort_d, Subnet1_s,
          DestIP_s, DestPort_d, Subnet2_s,
          NSGRule_s
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
          Caller, CallerIpAddress
| sort by TimeGenerated desc'
}

$queries["pe-dns"] = @{
    Category    = 'Private Endpoint'
    Description = 'Private DNS zone changes — A-record registrations for private endpoints'
    KQL         = 'AzureActivity
| where OperationNameValue has "Microsoft.Network/privateDnsZones"
| project TimeGenerated, OperationNameValue, ActivityStatusValue,
          ResourceGroup, Resource = _ResourceId,
          Caller, CallerIpAddress
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
          ResourceGroup, Resource = _ResourceId,
          Caller, CallerIpAddress
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
          ResourceGroup, Resource = _ResourceId,
          Caller, CallerIpAddress
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
    Write-Host "  TimeRange examples (ISO 8601 duration):" -ForegroundColor Cyan
    Write-Host "    PT30M  — last 30 minutes"
    Write-Host "    PT1H   — last 1 hour"
    Write-Host "    PT6H   — last 6 hours"
    Write-Host "    P1D    — last 1 day (default)"
    Write-Host "    P3D    — last 3 days"
    Write-Host "    P7D    — last 7 days"
    Write-Host "    P30D   — last 30 days"
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

if ($PSCmdlet.ParameterSetName -eq 'List') {
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
    Write-Host "  |  TimeRange: $TimeRange    Top: $(if ($Top -gt 0) { $Top } else { 'unlimited' })"
    if ($ResourceFilter) {
        Write-Host "  |  Filter   : $ResourceFilter" -ForegroundColor Yellow
    }
    Write-Host "  +----------------------------------------------" -ForegroundColor Cyan

    # Collapse multi-line KQL into a single line so az CLI passes it intact
    # Replace double quotes with single quotes — KQL accepts both, and double
    # quotes get stripped by the Windows command processor when passed to az CLI
    $kqlOneLine = ($kql -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }) -join ' '
    $kqlOneLine = $kqlOneLine -replace '"', "'"

    $queryArgs = @(
        'monitor', 'log-analytics', 'query',
        '--workspace', $WorkspaceId,
        '--analytics-query', $kqlOneLine,
        '--timespan', $TimeRange,
        '-o', 'json'
    )
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $raw = & az @queryArgs 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP

    if ($exitCode -ne 0) {
        $msg = ($raw | Out-String).Trim()
        if ($msg -match 'BadArgumentError|SemanticError|is not recognized as a|not a valid table|could not be found') {
            Write-Host '    ⚠ Table/column not available — diagnostics may not be configured for this resource.' -ForegroundColor DarkYellow
            Write-Host "    $($msg.Substring(0, [Math]::Min($msg.Length, 200)))" -ForegroundColor DarkGray
        }
        else {
            Write-Host "    ❌ Error: $($msg.Substring(0, [Math]::Min($msg.Length, 300)))" -ForegroundColor Red
        }
        continue
    }

    $rows = @($raw | ConvertFrom-Json)
    # Flatten nested arrays from ConvertFrom-Json (it wraps [] as a single element)
    if ($rows.Count -eq 1 -and $rows[0] -is [System.Collections.IEnumerable] -and $rows[0] -isnot [string]) {
        $rows = @($rows[0])
    }
    if ($rows.Count -gt 0) {
        Write-Host "    ✅ $($rows.Count) row(s) returned" -ForegroundColor Green
        # Get column names excluding the API metadata column, force all to display
        $cols = @($rows[0].PSObject.Properties.Name | Where-Object { $_ -ne 'TableName' })
        $rows | Select-Object -Property $cols | Format-Table -AutoSize -Wrap
    }
    else {
        Write-Host "    (no results for this time range)" -ForegroundColor DarkGray
    }
}

Write-Host ''
Write-Host '  Done.' -ForegroundColor Green
