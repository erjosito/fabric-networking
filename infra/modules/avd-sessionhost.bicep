@description('VM name (also used as computer name, truncated to 15 chars)')
param name string

@description('Azure region')
param location string

@description('Subnet resource ID for the NIC')
param subnetId string

@description('VM size')
param vmSize string

@description('Local admin username')
param adminUsername string

@secure()
@description('Local admin password')
param adminPassword string

@description('AVD host pool name to register with')
param hostPoolName string

@secure()
@description('AVD host pool registration token')
param registrationToken string

@description('URL to the AVD agent DSC configuration zip')
#disable-next-line no-hardcoded-env-urls
param artifactsLocation string = 'https://wvdportalstorageblob.blob.core.windows.net/galleryartifacts/Configuration_09-08-2022.zip'

resource nic 'Microsoft.Network/networkInterfaces@2024-03-01' = {
  name: '${name}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: subnetId }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: name
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: take(name, 15)
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsDesktop'
        offer: 'windows-11'
        sku: 'win11-24h2-avd'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [{ id: nic.id }]
    }
    licenseType: 'Windows_Client'
  }
}

resource aadLoginExtension 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = {
  parent: vm
  name: 'AADLoginForWindows'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADLoginForWindows'
    typeHandlerVersion: '2.0'
    autoUpgradeMinorVersion: true
  }
}

resource dscExtension 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = {
  parent: vm
  name: 'DSC'
  location: location
  dependsOn: [aadLoginExtension]
  properties: {
    publisher: 'Microsoft.Powershell'
    type: 'DSC'
    typeHandlerVersion: '2.73'
    autoUpgradeMinorVersion: true
    settings: {
      modulesUrl: artifactsLocation
      configurationFunction: 'Configuration.ps1\\AddSessionHost'
      properties: {
        hostPoolName: hostPoolName
        aadJoin: true
      }
    }
    protectedSettings: {
      properties: {
        registrationInfoToken: registrationToken
      }
    }
  }
}

output vmId string = vm.id
output vmName string = vm.name
