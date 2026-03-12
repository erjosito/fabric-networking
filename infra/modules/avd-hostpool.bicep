@description('Name of the AVD host pool')
param name string

@description('Azure region')
param location string

@description('Friendly display name')
param friendlyName string

@description('Base time for registration token expiry — pass utcNow() from parent template')
param baseTime string

resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2024-04-03' = {
  name: name
  location: location
  properties: {
    hostPoolType: 'Personal'
    loadBalancerType: 'Persistent'
    personalDesktopAssignmentType: 'Automatic'
    preferredAppGroupType: 'Desktop'
    friendlyName: friendlyName
    // Always generate a fresh token. Existing session hosts ignore it —
    // they only use the token during initial DSC registration.
    registrationInfo: {
      expirationTime: dateTimeAdd(baseTime, 'PT48H')
      registrationTokenOperation: 'Update'
    }
  }
}

resource appGroup 'Microsoft.DesktopVirtualization/applicationGroups@2024-04-03' = {
  name: '${name}-dag'
  location: location
  properties: {
    applicationGroupType: 'Desktop'
    hostPoolArmPath: hostPool.id
    friendlyName: '${friendlyName} Desktop'
  }
}

resource workspace 'Microsoft.DesktopVirtualization/workspaces@2024-04-03' = {
  name: '${name}-ws'
  location: location
  properties: {
    friendlyName: '${friendlyName} Workspace'
    applicationGroupReferences: [
      appGroup.id
    ]
  }
}

output hostPoolName string = hostPool.name
output hostPoolId string = hostPool.id
output appGroupName string = appGroup.name
output appGroupId string = appGroup.id
