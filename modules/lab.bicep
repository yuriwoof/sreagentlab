// Shared lab infrastructure; SRE Agent and its dedicated resources are deployed separately.
targetScope = 'resourceGroup'

param location string
param prefix string
param tags object
param adminUsername string
@secure()
param adminPassword string
param vmCount int
param vmSize string
param enableRdpPublicIp bool
param allowedRdpSource string
param alertEmail string
param lawName string

var names = [for i in range(0, vmCount): '${prefix}-vm-${padLeft(string(i + 1), 2, '0')}']
var readerRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')

module network 'network.bicep' = {
  name: 'deploy-network'
  params: {
    location: location
    prefix: prefix
    tags: tags
    enableRdpPublicIp: enableRdpPublicIp
    allowedRdpSource: allowedRdpSource
  }
}
module vm 'vm.bicep' = {
  name: 'deploy-vm'
  params: {
    location: location
    prefix: prefix
    tags: tags
    subnetId: network.outputs.subnetId
    adminUsername: adminUsername
    adminPassword: adminPassword
    vmSize: vmSize
    vmCount: vmCount
    enableRdpPublicIp: enableRdpPublicIp
  }
}
module appGw 'appgw.bicep' = {
  name: 'deploy-appgw'
  params: {
    location: location
    prefix: prefix
    tags: tags
    subnetId: network.outputs.appGwSubnetId
    backendIpAddresses: vm.outputs.privateIpAddresses
  }
}
module monitoring 'monitoring.bicep' = {
  name: 'deploy-monitoring'
  params: {
    location: location
    prefix: prefix
    tags: tags
    vmIds: vm.outputs.vmIds
    vmNames: vm.outputs.vmNames
    appGwName: appGw.outputs.appGwName
    alertEmail: alertEmail
    lawName: lawName
  }
}
module chaos 'chaos.bicep' = {
  name: 'deploy-chaos'
  params: {
    location: location
    prefix: prefix
    tags: tags
    vmNames: vm.outputs.vmNames
    chaosIdentityClientId: vm.outputs.chaosIdentityClientId
  }
  dependsOn: [
    monitoring
    chaosAgentReaderRoles
  ]
}

resource targetVms 'Microsoft.Compute/virtualMachines@2024-07-01' existing = [for name in names: {
  name: name
}]
resource chaosAgentReaderRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for i in range(0, vmCount): {
  name: guid(targetVms[i].id, '${prefix}-chaos-identity', readerRoleId)
  scope: targetVms[i]
  properties: {
    principalId: vm.outputs.chaosIdentityPrincipalId
    roleDefinitionId: readerRoleId
    principalType: 'ServicePrincipal'
  }
}]
// CPU and memory target all VMs; IIS and disk IO target vm-01 only.
var cpuBindings = [for i in range(0, vmCount): { experiment: 0, vm: i }]
var memoryBindings = [for i in range(0, vmCount): { experiment: 1, vm: i }]
var readerBindings = concat(cpuBindings, memoryBindings, [{ experiment: 2, vm: 0 }, { experiment: 3, vm: 0 }])
resource experimentReaderRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for binding in readerBindings: {
  name: guid(targetVms[binding.vm].id, prefix, string(binding.experiment), readerRoleId)
  scope: targetVms[binding.vm]
  properties: {
    principalId: chaos.outputs.experimentPrincipalIds[binding.experiment]
    roleDefinitionId: readerRoleId
    principalType: 'ServicePrincipal'
  }
}]

output vmNames string[] = vm.outputs.vmNames
output vmIds string[] = vm.outputs.vmIds
output appGwPublicIp string = appGw.outputs.appGwPublicIp
output appGwName string = appGw.outputs.appGwName
output appGwId string = appGw.outputs.appGwId
output probeName string = appGw.outputs.probeName
output nsgName string = network.outputs.nsgName
output nsgId string = network.outputs.nsgId
output appGwSubnetPrefix string = network.outputs.appGwSubnetPrefix
output vmSubnetPrefix string = network.outputs.vmSubnetPrefix
output lawName string = monitoring.outputs.lawName
output lawId string = monitoring.outputs.lawId
output experimentNames object = chaos.outputs.experimentNames
output resourceGroupName string = resourceGroup().name
