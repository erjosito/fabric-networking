// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║  Fabric Workspace-Level Private Link                                        ║
// ║  Creates the Microsoft.Fabric/privateLinkServicesForFabric resource,         ║
// ║  a Private DNS zone for *.fabric.microsoft.com, VNet links, and             ║
// ║  Private Endpoints scoped to a single workspace.                            ║
// ║                                                                              ║
// ║  Prerequisites:                                                              ║
// ║   1. Enable "Configure workspace-level inbound network rules" in Fabric      ║
// ║      Admin > Tenant Settings                                                 ║
// ║   2. Workspace must be assigned to a Fabric capacity (F SKU)                 ║
// ║   3. Register the Microsoft.Fabric resource provider in the subscription     ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

targetScope = 'resourceGroup'

// ── Parameters ─────────────────────────────────────────────────────────────────

@description('Azure region for Private Endpoints')
param location string = 'canadacentral'

@description('Resource name prefix')
param prefix string = 'fabnet'

@description('Microsoft Entra tenant ID')
param tenantId string

@description('Fabric workspace ID (GUID)')
param workspaceId string

@description('Suffix to identify this workspace link (e.g. workspace name or short alias)')
param workspaceSuffix string

@description('Resource IDs of the VNets to link the Private DNS zone to')
param vnetIds array

@description('Subnet resource IDs where Fabric workspace Private Endpoints will be created')
param peSubnetIds array

// ── Fabric Workspace Private Link Service ──────────────────────────────────────

resource fabricWorkspacePls 'Microsoft.Fabric/privateLinkServicesForFabric@2024-06-01' = {
  name: '${prefix}-ws-pls-${workspaceSuffix}'
  location: 'global'
  properties: {
    tenantId: tenantId
    workspaceId: workspaceId
  }
}

// ── Private DNS Zone ───────────────────────────────────────────────────────────

resource dnsZoneFabric 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.fabric.microsoft.com'
  location: 'global'
}

resource dnsZoneLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for (vnetId, i) in vnetIds: {
  parent: dnsZoneFabric
  name: '${prefix}-ws-fabric-dns-link-${i}'
  location: 'global'
  properties: {
    virtualNetwork: { id: vnetId }
    registrationEnabled: false
  }
}]

// ── Private Endpoints (one per VNet) ───────────────────────────────────────────

resource workspaceEndpoints 'Microsoft.Network/privateEndpoints@2024-03-01' = [for (subnetId, i) in peSubnetIds: {
  name: '${prefix}-pe-ws-${workspaceSuffix}-${i}'
  location: location
  properties: {
    subnet: { id: subnetId }
    privateLinkServiceConnections: [
      {
        name: '${prefix}-ws-conn-${workspaceSuffix}-${i}'
        properties: {
          privateLinkServiceId: fabricWorkspacePls.id
          groupIds: ['workspace']
        }
      }
    ]
  }
}]

resource workspaceDnsGroups 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-03-01' = [for (subnetId, i) in peSubnetIds: {
  parent: workspaceEndpoints[i]
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'fabric-microsoft-com'
        properties: {
          privateDnsZoneId: dnsZoneFabric.id
        }
      }
    ]
  }
}]

// ── Outputs ────────────────────────────────────────────────────────────────────

output fabricWorkspacePlsId string = fabricWorkspacePls.id
output fabricWorkspacePlsName string = fabricWorkspacePls.name
output privateDnsZoneId string = dnsZoneFabric.id
