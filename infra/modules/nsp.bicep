@description('Name of the Network Security Perimeter')
param name string

@description('Azure region')
param location string

@description('Resource ID of the SQL Server to associate')
param sqlServerId string

@description('Resource ID of the Storage Account to associate')
param storageAccountId string

@description('Log Analytics workspace resource ID for diagnostics')
param logAnalyticsWorkspaceId string

resource nsp 'Microsoft.Network/networkSecurityPerimeters@2023-08-01-preview' = {
  name: name
  location: location
}

resource profile 'Microsoft.Network/networkSecurityPerimeters/profiles@2023-08-01-preview' = {
  parent: nsp
  name: '${name}-profile'
  location: location
  properties: {}
}

resource inboundRule 'Microsoft.Network/networkSecurityPerimeters/profiles/accessRules@2023-08-01-preview' = {
  parent: profile
  name: 'allow-inbound'
  location: location
  properties: {
    direction: 'Inbound'
    addressPrefixes: ['*']
  }
}

resource sqlAssociation 'Microsoft.Network/networkSecurityPerimeters/resourceAssociations@2023-08-01-preview' = {
  parent: nsp
  name: '${name}-sql'
  location: location
  properties: {
    privateLinkResource: {
      id: sqlServerId
    }
    profile: {
      id: profile.id
    }
    accessMode: 'Learning'
  }
}

resource storageAssociation 'Microsoft.Network/networkSecurityPerimeters/resourceAssociations@2023-08-01-preview' = {
  parent: nsp
  name: '${name}-storage'
  location: location
  properties: {
    privateLinkResource: {
      id: storageAccountId
    }
    profile: {
      id: profile.id
    }
    accessMode: 'Learning'
  }
}

resource nspDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${name}-diagnostics'
  scope: nsp
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

output id string = nsp.id
