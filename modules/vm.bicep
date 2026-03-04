// =============================================================================
// Module: vm.bicep
// Description: Linux VM with nginx (simulated web workload) + User-Assigned
//              Managed Identity for Chaos Studio agent.
// =============================================================================

@description('Azure region for deployment')
param location string

@description('Resource name prefix')
param prefix string

@description('Subnet resource ID to attach the NIC')
param subnetId string

@description('Public IP resource ID')
param publicIpId string

@description('VM admin username')
param adminUsername string

@description('SSH public key for VM authentication')
@secure()
param sshPublicKey string

@description('VM size')
param vmSize string = 'Standard_B2s'

// ---------------------------------------------------------------------------
// User-Assigned Managed Identity (for Chaos Studio agent)
// ---------------------------------------------------------------------------
resource chaosIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${prefix}-chaos-identity'
  location: location
}

// ---------------------------------------------------------------------------
// Network Interface
// ---------------------------------------------------------------------------
resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${prefix}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnetId
          }
          publicIPAddress: {
            id: publicIpId
          }
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Virtual Machine
// ---------------------------------------------------------------------------
resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: '${prefix}-vm'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${chaosIdentity.id}': {}
    }
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: '${prefix}-vm'
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        name: '${prefix}-osdisk'
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Custom Script Extension – install nginx as a demo workload
// ---------------------------------------------------------------------------
resource nginxExtension 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: vm
  name: 'install-nginx'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Extensions'
    type: 'CustomScript'
    typeHandlerVersion: '2.1'
    autoUpgradeMinorVersion: true
    settings: {
      commandToExecute: 'export DEBIAN_FRONTEND=noninteractive && apt-get update && apt-get install -y software-properties-common && add-apt-repository -y universe && apt-get update && apt-get install -y nginx stress-ng && systemctl enable nginx && systemctl start nginx'
    }
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output vmId string = vm.id
output vmName string = vm.name
output chaosIdentityId string = chaosIdentity.id
output chaosIdentityPrincipalId string = chaosIdentity.properties.principalId
output chaosIdentityClientId string = chaosIdentity.properties.clientId
