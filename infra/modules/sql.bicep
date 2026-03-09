@description('SQL Server name (globally unique)')
param serverName string

@description('Azure region')
param location string

@description('Database name')
param databaseName string

@description('Object ID of the Entra ID principal to set as SQL admin')
param entraAdminObjectId string

@description('Display name of the Entra ID principal to set as SQL admin')
param entraAdminName string

@description('Log Analytics workspace resource ID for diagnostics (empty to skip)')
param logAnalyticsWorkspaceId string = ''

resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: serverName
  location: location
  properties: {
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    administrators: {
      administratorType: 'ActiveDirectory'
      login: entraAdminName
      sid: entraAdminObjectId
      tenantId: tenant().tenantId
      azureADOnlyAuthentication: true
      principalType: 'User'
    }
  }
}

// Allow Azure services (including Microsoft Fabric) to reach SQL Server
resource firewallAllowAzure 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = {
  parent: sqlServer
  name: 'AllowAllWindowsAzureIps'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

resource database 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: sqlServer
  name: databaseName
  location: location
  sku: {
    name: 'Basic'
    tier: 'Basic'
    capacity: 5
  }
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    maxSizeBytes: 2147483648 // 2 GB
  }
}

resource dbDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceId)) {
  name: '${databaseName}-diagnostics'
  scope: database
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      { category: 'SQLInsights', enabled: true }
      { category: 'Errors', enabled: true }
      { category: 'DatabaseWaitStatistics', enabled: true }
      { category: 'Timeouts', enabled: true }
      { category: 'Blocks', enabled: true }
      { category: 'Deadlocks', enabled: true }
    ]
    metrics: [
      { category: 'Basic', enabled: true }
    ]
  }
}

output serverId string = sqlServer.id
output serverName string = sqlServer.name
output serverFqdn string = sqlServer.properties.fullyQualifiedDomainName
output databaseName string = database.name
