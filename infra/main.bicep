// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║  Fabric Networking Test Infrastructure                                      ║
// ║  Deploys two isolated VNets with AVD pools, Azure SQL, Storage,             ║
// ║  full monitoring, Private Endpoints, and a Network Security Perimeter.      ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

targetScope = 'resourceGroup'

// ── Parameters ─────────────────────────────────────────────────────────────────

@description('Azure region for all resources')
param location string = 'canadacentral'

@description('Resource name prefix')
param prefix string = 'fabnet'

@description('Base time for AVD registration token expiry (do not override manually)')
param baseTime string = utcNow()

@description('Whether to deploy AVD session host VMs (set to false on re-deploys to avoid DSC re-registration)')
param deploySessionHosts bool = true

@description('VM admin username')
param vmAdminUsername string = 'azureuser'

@secure()
@description('VM admin password (only required when deploySessionHosts is true)')
param vmAdminPassword string = ''

@description('VM size for AVD session hosts')
param vmSize string = 'Standard_D2s_v5'

@description('Object ID of the Entra ID user or group to set as SQL Server admin')
param sqlEntraAdminObjectId string

@description('Display name of the Entra ID SQL admin')
param sqlEntraAdminName string

@description('Name of the existing Network Watcher (auto-created by Azure)')
param networkWatcherName string = 'NetworkWatcher_${location}'

@description('Resource group that contains the Network Watcher')
param networkWatcherResourceGroup string = 'NetworkWatcherRG'

// ── Variables ──────────────────────────────────────────────────────────────────

var uniqueSuffix = uniqueString(resourceGroup().id)
var loggingStorageName = take(toLower('${prefix}log${uniqueSuffix}'), 24)
var dataStorageName = take(toLower('${prefix}data${uniqueSuffix}'), 24)
var sqlServerName = toLower('${prefix}-sql-${uniqueSuffix}')

// ── Monitoring ─────────────────────────────────────────────────────────────────

module logAnalytics 'modules/log-analytics.bicep' = {
  name: 'logAnalytics'
  params: {
    name: '${prefix}-log'
    location: location
  }
}

module loggingStorage 'modules/storage.bicep' = {
  name: 'loggingStorage'
  params: {
    name: loggingStorageName
    location: location
  }
}

// ── Data Storage ───────────────────────────────────────────────────────────────

module dataStorage 'modules/storage.bicep' = {
  name: 'dataStorage'
  params: {
    name: dataStorageName
    location: location
    logAnalyticsWorkspaceId: logAnalytics.outputs.id
  }
}

// ── Networking ─────────────────────────────────────────────────────────────────

module vnetA 'modules/vnet.bicep' = {
  name: 'vnetA'
  params: {
    name: '${prefix}-vnet-a'
    location: location
    addressPrefix: '10.0.0.0/16'
    avdSubnetPrefix: '10.0.1.0/24'
    peSubnetPrefix: '10.0.2.0/24'
  }
}

module vnetB 'modules/vnet.bicep' = {
  name: 'vnetB'
  params: {
    name: '${prefix}-vnet-b'
    location: location
    addressPrefix: '10.1.0.0/16'
    avdSubnetPrefix: '10.1.1.0/24'
    peSubnetPrefix: '10.1.2.0/24'
  }
}

// ── AVD Host Pools ─────────────────────────────────────────────────────────────

module avdHostPoolA 'modules/avd-hostpool.bicep' = {
  name: 'avdHostPoolA'
  params: {
    name: '${prefix}-hp-a'
    location: location
    friendlyName: 'Fabric Test Pool A'
    baseTime: baseTime
    generateToken: deploySessionHosts
  }
}

module avdHostPoolB 'modules/avd-hostpool.bicep' = {
  name: 'avdHostPoolB'
  params: {
    name: '${prefix}-hp-b'
    location: location
    friendlyName: 'Fabric Test Pool B'
    baseTime: baseTime
    generateToken: deploySessionHosts
  }
}

// ── AVD Session Hosts (only on first deploy or when explicitly requested) ──────

module avdSessionHostA 'modules/avd-sessionhost.bicep' = if (deploySessionHosts) {
  name: 'avdSessionHostA'
  params: {
    name: '${prefix}-vm-a'
    location: location
    subnetId: vnetA.outputs.avdSubnetId
    vmSize: vmSize
    adminUsername: vmAdminUsername
    adminPassword: vmAdminPassword
    hostPoolName: avdHostPoolA.outputs.hostPoolName
    registrationToken: avdHostPoolA.outputs.registrationToken
  }
}

module avdSessionHostB 'modules/avd-sessionhost.bicep' = if (deploySessionHosts) {
  name: 'avdSessionHostB'
  params: {
    name: '${prefix}-vm-b'
    location: location
    subnetId: vnetB.outputs.avdSubnetId
    vmSize: vmSize
    adminUsername: vmAdminUsername
    adminPassword: vmAdminPassword
    hostPoolName: avdHostPoolB.outputs.hostPoolName
    registrationToken: avdHostPoolB.outputs.registrationToken
  }
}

// ── Azure SQL ──────────────────────────────────────────────────────────────────

module sql 'modules/sql.bicep' = {
  name: 'sql'
  params: {
    serverName: sqlServerName
    location: location
    databaseName: '${prefix}-db'
    entraAdminObjectId: sqlEntraAdminObjectId
    entraAdminName: sqlEntraAdminName
    logAnalyticsWorkspaceId: logAnalytics.outputs.id
  }
}

// ── Private DNS Zones ──────────────────────────────────────────────────────────

resource privateDnsZoneSql 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink${environment().suffixes.sqlServerHostname}'
  location: 'global'
}

resource privateDnsZoneBlob 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.blob.${environment().suffixes.storage}'
  location: 'global'
}

// Link SQL DNS zone to both VNets
resource sqlDnsLinkA 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZoneSql
  name: '${prefix}-sql-link-a'
  location: 'global'
  properties: {
    virtualNetwork: { id: vnetA.outputs.id }
    registrationEnabled: false
  }
}

resource sqlDnsLinkB 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZoneSql
  name: '${prefix}-sql-link-b'
  location: 'global'
  properties: {
    virtualNetwork: { id: vnetB.outputs.id }
    registrationEnabled: false
  }
}

// Link Blob DNS zone to both VNets
resource blobDnsLinkA 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZoneBlob
  name: '${prefix}-blob-link-a'
  location: 'global'
  properties: {
    virtualNetwork: { id: vnetA.outputs.id }
    registrationEnabled: false
  }
}

resource blobDnsLinkB 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZoneBlob
  name: '${prefix}-blob-link-b'
  location: 'global'
  properties: {
    virtualNetwork: { id: vnetB.outputs.id }
    registrationEnabled: false
  }
}

// ── Private Endpoints ──────────────────────────────────────────────────────────

module peSqlA 'modules/private-endpoint.bicep' = {
  name: 'peSqlA'
  params: {
    name: '${prefix}-pe-sql-a'
    location: location
    subnetId: vnetA.outputs.peSubnetId
    privateLinkServiceId: sql.outputs.serverId
    groupIds: ['sqlServer']
    privateDnsZoneId: privateDnsZoneSql.id
  }
}

module peSqlB 'modules/private-endpoint.bicep' = {
  name: 'peSqlB'
  params: {
    name: '${prefix}-pe-sql-b'
    location: location
    subnetId: vnetB.outputs.peSubnetId
    privateLinkServiceId: sql.outputs.serverId
    groupIds: ['sqlServer']
    privateDnsZoneId: privateDnsZoneSql.id
  }
}

module peStorageA 'modules/private-endpoint.bicep' = {
  name: 'peStorageA'
  params: {
    name: '${prefix}-pe-blob-a'
    location: location
    subnetId: vnetA.outputs.peSubnetId
    privateLinkServiceId: dataStorage.outputs.id
    groupIds: ['blob']
    privateDnsZoneId: privateDnsZoneBlob.id
  }
}

module peStorageB 'modules/private-endpoint.bicep' = {
  name: 'peStorageB'
  params: {
    name: '${prefix}-pe-blob-b'
    location: location
    subnetId: vnetB.outputs.peSubnetId
    privateLinkServiceId: dataStorage.outputs.id
    groupIds: ['blob']
    privateDnsZoneId: privateDnsZoneBlob.id
  }
}

// ── VNet Flow Logs ─────────────────────────────────────────────────────────────

module flowLogA 'modules/vnet-flow-logs.bicep' = {
  name: 'flowLogA'
  scope: resourceGroup(networkWatcherResourceGroup)
  params: {
    name: '${prefix}-flowlog-vnet-a'
    location: location
    networkWatcherName: networkWatcherName
    targetResourceId: vnetA.outputs.id
    storageAccountId: loggingStorage.outputs.id
    logAnalyticsWorkspaceId: logAnalytics.outputs.id
    logAnalyticsWorkspaceGuid: logAnalytics.outputs.customerId
    logAnalyticsWorkspaceLocation: location
  }
}

module flowLogB 'modules/vnet-flow-logs.bicep' = {
  name: 'flowLogB'
  scope: resourceGroup(networkWatcherResourceGroup)
  params: {
    name: '${prefix}-flowlog-vnet-b'
    location: location
    networkWatcherName: networkWatcherName
    targetResourceId: vnetB.outputs.id
    storageAccountId: loggingStorage.outputs.id
    logAnalyticsWorkspaceId: logAnalytics.outputs.id
    logAnalyticsWorkspaceGuid: logAnalytics.outputs.customerId
    logAnalyticsWorkspaceLocation: location
  }
}

// ── Network Security Perimeter ─────────────────────────────────────────────────

module nsp 'modules/nsp.bicep' = {
  name: 'nsp'
  params: {
    name: '${prefix}-nsp'
    location: location
    sqlServerId: sql.outputs.serverId
    storageAccountId: dataStorage.outputs.id
    logAnalyticsWorkspaceId: logAnalytics.outputs.id
  }
}

// ── Outputs ────────────────────────────────────────────────────────────────────

output logAnalyticsWorkspaceId string = logAnalytics.outputs.id
output loggingStorageAccountName string = loggingStorage.outputs.name
output dataStorageAccountName string = dataStorage.outputs.name
output sqlServerFqdn string = sql.outputs.serverFqdn
output sqlDatabaseName string = sql.outputs.databaseName
output vnetAId string = vnetA.outputs.id
output vnetBId string = vnetB.outputs.id
output avdHostPoolAName string = avdHostPoolA.outputs.hostPoolName
output avdHostPoolBName string = avdHostPoolB.outputs.hostPoolName
