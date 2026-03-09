@description('Name of the private endpoint')
param name string

@description('Azure region')
param location string

@description('Subnet resource ID to place the endpoint in')
param subnetId string

@description('Resource ID of the target PaaS service')
param privateLinkServiceId string

@description('Sub-resource group IDs (e.g. sqlServer, blob)')
param groupIds array

@description('Private DNS zone resource ID for automatic DNS registration')
param privateDnsZoneId string

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-03-01' = {
  name: name
  location: location
  properties: {
    subnet: { id: subnetId }
    privateLinkServiceConnections: [
      {
        name: '${name}-conn'
        properties: {
          privateLinkServiceId: privateLinkServiceId
          groupIds: groupIds
        }
      }
    ]
  }
}

resource dnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-03-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'config1'
        properties: {
          privateDnsZoneId: privateDnsZoneId
        }
      }
    ]
  }
}

output id string = privateEndpoint.id
