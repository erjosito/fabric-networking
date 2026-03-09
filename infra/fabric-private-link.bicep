// ╔══════════════════════════════════════════════════════════════════════════════╗
// ║  Fabric / Power BI Tenant-Level Private Link                                ║
// ║  Creates the Microsoft.PowerBI/privateLinkServicesForPowerBI resource,       ║
// ║  Fabric-specific Private DNS zones, VNet links, and Private Endpoints.       ║
// ║                                                                              ║
// ║  Prerequisites:                                                              ║
// ║   1. Enable "Azure Private Link" in Fabric Admin > Tenant Settings           ║
// ║   2. Wait ~15 minutes for the FQDN configuration to propagate               ║
// ╚══════════════════════════════════════════════════════════════════════════════╝

targetScope = 'resourceGroup'

// ── Parameters ─────────────────────────────────────────────────────────────────

@description('Azure region (must match your Fabric home region)')
param location string = 'canadacentral'

@description('Resource name prefix')
param prefix string = 'fabnet'

@description('Microsoft Entra tenant ID — discovered automatically by the deploy script')
param tenantId string

@description('Resource IDs of the VNets to link Private DNS zones to')
param vnetIds array

@description('Subnet resource IDs where Fabric Private Endpoints will be created')
param peSubnetIds array

// ── Fabric Private Link Service ────────────────────────────────────────────────

resource fabricPrivateLink 'Microsoft.PowerBI/privateLinkServicesForPowerBI@2020-06-01' = {
  name: '${prefix}-fabric-pls'
  location: 'global'
  properties: {
    tenantId: tenantId
  }
}

// ── Private DNS Zones (required for Fabric / Power BI resolution) ──────────────

var fabricDnsZones = [
  'privatelink.analysis.windows.net'
  'privatelink.pbidedicated.windows.net'
  'privatelink.prod.powerquery.microsoft.com'
]

resource dnsZones 'Microsoft.Network/privateDnsZones@2020-06-01' = [for zone in fabricDnsZones: {
  name: zone
  location: 'global'
}]

// Link each DNS zone to each VNet
resource dnsZoneLinksFlat 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for i in range(0, length(fabricDnsZones) * length(vnetIds)): {
  parent: dnsZones[i / length(vnetIds)]
  name: '${prefix}-fabric-dns-link-${i}'
  location: 'global'
  properties: {
    virtualNetwork: { id: vnetIds[i % length(vnetIds)] }
    registrationEnabled: false
  }
}]

// ── Private Endpoints for Fabric (one per VNet) ────────────────────────────────

resource fabricEndpoints 'Microsoft.Network/privateEndpoints@2024-03-01' = [for (subnetId, i) in peSubnetIds: {
  name: '${prefix}-pe-fabric-${i}'
  location: location
  properties: {
    subnet: { id: subnetId }
    privateLinkServiceConnections: [
      {
        name: '${prefix}-fabric-conn-${i}'
        properties: {
          privateLinkServiceId: fabricPrivateLink.id
          groupIds: ['Tenant']
        }
      }
    ]
  }
}]

resource fabricDnsGroups 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-03-01' = [for (subnetId, i) in peSubnetIds: {
  parent: fabricEndpoints[i]
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [for (zone, z) in fabricDnsZones: {
      name: replace(replace(zone, '.', '-'), 'privatelink-', '')
      properties: {
        privateDnsZoneId: dnsZones[z].id
      }
    }]
  }
}]

// ── Outputs ────────────────────────────────────────────────────────────────────

output fabricPrivateLinkServiceId string = fabricPrivateLink.id
output fabricPrivateLinkServiceName string = fabricPrivateLink.name
output privateDnsZoneIds array = [for (zone, z) in fabricDnsZones: dnsZones[z].id]
