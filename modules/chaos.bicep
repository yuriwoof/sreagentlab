// =============================================================================
// Module: chaos.bicep
// Description: Windows Chaos targets, agents, capabilities, and experiments.
// =============================================================================

param location string
param prefix string
param tags object
param vmNames string[]
param chaosIdentityClientId string

resource vms 'Microsoft.Compute/virtualMachines@2024-07-01' existing = [for name in vmNames: {
  name: name
}]

resource targets 'Microsoft.Chaos/targets@2024-01-01' = [for i in range(0, length(vmNames)): {
  name: 'Microsoft-Agent'
  scope: vms[i]
  properties: {
    identities: [
      {
        type: 'AzureManagedIdentity'
        clientId: chaosIdentityClientId
        tenantId: tenant().tenantId
      }
    ]
  }
}]

resource cpuCapabilities 'Microsoft.Chaos/targets/capabilities@2024-01-01' = [for i in range(0, length(vmNames)): {
  parent: targets[i]
  name: 'CPUPressure-1.0'
}]
resource memoryCapabilities 'Microsoft.Chaos/targets/capabilities@2024-01-01' = [for i in range(0, length(vmNames)): {
  parent: targets[i]
  name: 'PhysicalMemoryPressure-1.0'
}]
resource serviceCapabilities 'Microsoft.Chaos/targets/capabilities@2024-01-01' = [for i in range(0, length(vmNames)): {
  parent: targets[i]
  name: 'StopService-1.0'
}]
resource diskCapabilities 'Microsoft.Chaos/targets/capabilities@2024-01-01' = [for i in range(0, length(vmNames)): {
  parent: targets[i]
  name: 'DiskIOPressure-1.1'
}]

resource agents 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = [for i in range(0, length(vmNames)): {
  parent: vms[i]
  name: 'ChaosAgent'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Azure.Chaos'
    type: 'ChaosWindowsAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
    settings: {
      profile: targets[i].properties.agentProfileId
      'auth.msi.clientid': chaosIdentityClientId
    }
  }
}]

// Verified against https://learn.microsoft.com/azure/chaos-studio/chaos-studio-fault-library
var definitions = [
  {
    key: 'cpu'
    name: '${prefix}-cpu-pressure-exp'
    urn: 'urn:csci:microsoft:agent:cpuPressure/1.0'
    duration: 'PT10M'
    firstVmOnly: false
    parameters: [{ key: 'pressureLevel', value: '95' }]
  }
  {
    key: 'memory'
    name: '${prefix}-memory-pressure-exp'
    urn: 'urn:csci:microsoft:agent:physicalMemoryPressure/1.0'
    duration: 'PT10M'
    firstVmOnly: false
    parameters: [{ key: 'pressureLevel', value: '90' }]
  }
  {
    key: 'iis'
    name: '${prefix}-stop-iis-exp'
    urn: 'urn:csci:microsoft:agent:stopService/1.0'
    duration: 'PT5M'
    firstVmOnly: true
    parameters: [{ key: 'serviceName', value: 'W3SVC' }]
  }
  {
    key: 'diskio'
    name: '${prefix}-exp-diskio'
    urn: 'urn:csci:microsoft:agent:diskIOPressure/1.1'
    duration: 'PT10M'
    firstVmOnly: true
    parameters: [
      { key: 'pressureMode', value: 'PremiumStorageP10IOPS' }
      { key: 'targetTempDirectory', value: 'C:\\ChaosTemp' }
    ]
  }
]

var vmTargetSelectors = [for name in vmNames: {
  id: extensionResourceId(resourceId('Microsoft.Compute/virtualMachines', name), 'Microsoft.Chaos/targets', 'Microsoft-Agent')
  type: 'ChaosTarget'
}]

resource experiments 'Microsoft.Chaos/experiments@2024-01-01' = [for definition in definitions: {
  name: definition.name
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    selectors: [
      {
        id: 'vms'
        type: 'List'
        targets: definition.firstVmOnly ? take(vmTargetSelectors, 1) : vmTargetSelectors
      }
    ]
    steps: [
      {
        name: definition.key
        branches: [
          {
            name: 'inject'
            actions: [
              {
                type: 'continuous'
                name: definition.urn
                duration: definition.duration
                parameters: definition.parameters
                selectorId: 'vms'
              }
            ]
          }
        ]
      }
    ]
  }
  dependsOn: [
    cpuCapabilities
    memoryCapabilities
    serviceCapabilities
    diskCapabilities
    agents
  ]
}]

output experimentNames object = {
  cpu: experiments[0].name
  memory: experiments[1].name
  iis: experiments[2].name
  diskio: experiments[3].name
}
output experimentPrincipalIds string[] = [for i in range(0, length(definitions)): experiments[i].identity.principalId]
