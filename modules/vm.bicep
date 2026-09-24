// =============================================================================
// Module: vm.bicep
// Description: Windows Server 2022 IIS VMs with a shared Chaos Studio identity
//              and per-VM system-assigned identities for Azure Monitor Agent.
// =============================================================================

@description('Azure region for deployment')
param location string

@description('Resource name prefix; prefix-vm-01 must fit the Windows 15-character computer name limit')
@minLength(1)
@maxLength(9)
param prefix string

@description('Tags applied to all supported resources')
param tags object = {}

@description('VM subnet resource ID')
param subnetId string

@description('VM administrator username')
param adminUsername string

@description('Windows administrator password')
@secure()
param adminPassword string

@description('VM size supporting the disk metrics used by this lab')
param vmSize string = 'Standard_D2s_v5'

@description('Number of IIS VMs')
@minValue(1)
@maxValue(99)
param vmCount int = 2

@description('Attach optional public IPs for RDP; also enable the restricted rule in the network module')
param enableRdpPublicIp bool = false

var names = [for i in range(0, vmCount): '${prefix}-vm-${padLeft(string(i + 1), 2, '0')}']
// Bicep base64 is UTF-8; decode explicitly instead of passing it to UTF-16LE -EncodedCommand.
var setupScriptBase64 = base64(loadTextContent('../scripts/setup-iis.ps1'))
var setupCommand = 'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(\'${setupScriptBase64}\'))))"'

// ---------------------------------------------------------------------------
// Shared User-Assigned Managed Identity (Chaos Studio agent)
// ---------------------------------------------------------------------------
resource chaosIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: '${prefix}-chaos-identity'
  location: location
  tags: tags
}

// ---------------------------------------------------------------------------
// Optional RDP public IPs and Network Interfaces
// ---------------------------------------------------------------------------
resource rdpPublicIps 'Microsoft.Network/publicIPAddresses@2024-05-01' = [for i in range(0, vmCount): if (enableRdpPublicIp) {
  name: '${names[i]}-rdp-pip'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}]

resource nics 'Microsoft.Network/networkInterfaces@2024-05-01' = [for i in range(0, vmCount): {
  name: '${names[i]}-nic'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnetId
          }
          publicIPAddress: enableRdpPublicIp ? {
            id: rdpPublicIps[i]!.id
          } : null
        }
      }
    ]
  }
}]

// ---------------------------------------------------------------------------
// Virtual Machines
// ---------------------------------------------------------------------------
resource vms 'Microsoft.Compute/virtualMachines@2024-07-01' = [for i in range(0, vmCount): {
  name: names[i]
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${chaosIdentity.id}': {}
    }
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: names[i]
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: false
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-azure-edition'
        version: 'latest'
      }
      osDisk: {
        name: '${names[i]}-osdisk'
        createOption: 'FromImage'
        // The image requires 127 GiB (cannot shrink to E4). Standard HDD limits IO to 500 IOPS.
        diskSizeGB: 127
        // Bypass host caching so disk-stress experiments reach the managed disk metrics.
        caching: 'None'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nics[i].id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}]

// ---------------------------------------------------------------------------
// Tag automatically created OS disks without redeclaring their creation data.
// Microsoft.Resources/tags has no newer stable API than 2021-04-01.
// ---------------------------------------------------------------------------
resource osDisks 'Microsoft.Compute/disks@2024-03-02' existing = [for name in names: {
  name: '${name}-osdisk'
}]
resource osDiskTags 'Microsoft.Resources/tags@2021-04-01' = [for i in range(0, vmCount): {
  name: 'default'
  scope: osDisks[i]
  properties: {
    tags: tags
  }
  dependsOn: [
    vms[i]
  ]
}]

// ---------------------------------------------------------------------------
// Custom Script Extension – configure the local IIS workload
// ---------------------------------------------------------------------------
resource iisExtensions 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = [for i in range(0, vmCount): {
  parent: vms[i]
  name: 'install-iis'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    protectedSettings: {
      commandToExecute: setupCommand
    }
  }
}]

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output vmIds string[] = [for i in range(0, vmCount): vms[i].id]
output vmNames string[] = names
output privateIpAddresses string[] = [for i in range(0, vmCount): nics[i].properties.ipConfigurations[0].properties.privateIPAddress]
output chaosIdentityId string = chaosIdentity.id
output chaosIdentityPrincipalId string = chaosIdentity.properties.principalId
output chaosIdentityClientId string = chaosIdentity.properties.clientId
