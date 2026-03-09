@description('Name of the AVD host pool')
param name string

@description('Azure region')
param location string

@description('Friendly display name')
param friendlyName string

@description('Base time for registration token expiry — pass utcNow() from parent template')
param baseTime string

@description('Whether to generate a new registration token (only needed when adding session hosts)')
param generateToken bool = true

resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2024-04-03' = {
  name: name
  location: location
  properties: {
    hostPoolType: 'Personal'
    loadBalancerType: 'Persistent'
    personalDesktopAssignmentType: 'Automatic'
    preferredAppGroupType: 'Desktop'
    friendlyName: friendlyName
    registrationInfo: generateToken ? {
      expirationTime: dateTimeAdd(baseTime, 'PT48H')
      registrationTokenOperation: 'Update'
    } : {
      registrationTokenOperation: 'None'
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
output registrationToken string = generateToken ? hostPool.properties.registrationInfo.token : ''
