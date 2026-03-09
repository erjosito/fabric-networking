@description('Name of the flow log resource')
param name string

@description('Azure region')
param location string

@description('Name of the existing Network Watcher in this resource group')
param networkWatcherName string

@description('Resource ID of the VNet to monitor')
param targetResourceId string

@description('Resource ID of the storage account for raw flow logs')
param storageAccountId string

@description('ARM resource ID of the Log Analytics workspace')
param logAnalyticsWorkspaceId string

@description('Customer ID (GUID) of the Log Analytics workspace')
param logAnalyticsWorkspaceGuid string

@description('Location of the Log Analytics workspace')
param logAnalyticsWorkspaceLocation string

resource networkWatcher 'Microsoft.Network/networkWatchers@2024-03-01' existing = {
  name: networkWatcherName
}

resource flowLog 'Microsoft.Network/networkWatchers/flowLogs@2024-03-01' = {
  parent: networkWatcher
  name: name
  location: location
  properties: {
    targetResourceId: targetResourceId
    storageId: storageAccountId
    enabled: true
    format: {
      type: 'JSON'
      version: 2
    }
    retentionPolicy: {
      days: 30
      enabled: true
    }
    flowAnalyticsConfiguration: {
      networkWatcherFlowAnalyticsConfiguration: {
        enabled: true
        workspaceResourceId: logAnalyticsWorkspaceId
        workspaceRegion: logAnalyticsWorkspaceLocation
        workspaceId: logAnalyticsWorkspaceGuid
        trafficAnalyticsInterval: 10
      }
    }
  }
}

output id string = flowLog.id
