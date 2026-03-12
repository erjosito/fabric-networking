@description('Name of the VNet')
param name string

@description('Azure region')
param location string

@description('VNet address space CIDR')
param addressPrefix string

@description('AVD subnet address prefix')
param avdSubnetPrefix string

@description('Private endpoint subnet address prefix')
param peSubnetPrefix string

// ── NAT Gateway (provides outbound internet for VMs) ─────────────────────────

resource natPublicIp 'Microsoft.Network/publicIPAddresses@2024-03-01' = {
  name: '${name}-nat-pip'
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource natGateway 'Microsoft.Network/natGateways@2024-03-01' = {
  name: '${name}-nat'
  location: location
  sku: { name: 'Standard' }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [{ id: natPublicIp.id }]
  }
}

// ── VNet ──────────────────────────────────────────────────────────────────────

resource vnet 'Microsoft.Network/virtualNetworks@2024-03-01' = {
  name: name
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [addressPrefix]
    }
    subnets: [
      {
        name: 'snet-avd'
        properties: {
          addressPrefix: avdSubnetPrefix
          natGateway: { id: natGateway.id }
        }
      }
      {
        name: 'snet-pe'
        properties: {
          addressPrefix: peSubnetPrefix
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

output id string = vnet.id
output name string = vnet.name
output avdSubnetId string = vnet.properties.subnets[0].id
output peSubnetId string = vnet.properties.subnets[1].id
