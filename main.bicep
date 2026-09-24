// =============================================================================
// main.bicep
// Description: Windows IIS VMs, Application Gateway, monitoring, Chaos Studio,
//              and Azure SRE Agent for a disposable demonstration environment.
// =============================================================================

targetScope = 'resourceGroup'

// East US 2 supports App Gateway v2 and Chaos Studio; verify subscription quota before deployment.
@description('Azure region for all regional resources. Verify SRE Agent availability, VM quota, and SKU availability before deployment.')
param location string = 'eastus2'
@description('Resource name prefix: 1-9 characters, starts with a letter, contains only letters, digits, or hyphens, and ends with a letter or digit.')
@minLength(1)
@maxLength(9)
param prefix string = 'srelab'
param tags object = {
  project: 'sreagentlab'
  env: 'demo'
}
@description('Windows administrator username: 1-20 letters, digits, underscores, or hyphens; starts with a letter and must not be a reserved name such as administrator or admin.')
@minLength(1)
@maxLength(20)
param adminUsername string = 'azureuser'
@description('Windows administrator password: 12-123 characters, at least three character classes, and must not contain the username.')
@secure()
@minLength(12)
@maxLength(123)
param adminPassword string
@minValue(1)
@maxValue(99)
param vmCount int = 2
param vmSize string = 'Standard_D2s_v5'
param enableRdpPublicIp bool = false
@description('Explicit restricted IPv4 CIDR when RDP is enabled; never use /0 or a wildcard')
param allowedRdpSource string = '127.0.0.1/32'
@description('Email address that receives Azure Monitor alert notifications.')
@minLength(3)
param alertEmail string
@description('Azure SRE Agent resource name.')
param sreAgentName string = '${prefix}-agent'
@allowed(['High', 'Low'])
param sreAgentAccessLevel string = 'High'
@allowed(['Review', 'Autonomous', 'ReadOnly'])
param sreAgentMode string = 'Review'
@description('Microsoft Entra object ID of the user who will administer this SRE Agent. Find it in Microsoft Entra ID > Users > your user > Object ID.')
@minLength(36)
@maxLength(36)
param deployerPrincipalId string

var names = [for i in range(0, vmCount): '${prefix}-vm-${padLeft(string(i + 1), 2, '0')}']
var readerRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')

// ===== Modules ===============================================================
module network 'modules/network.bicep' = {
  name: 'deploy-network'
  params: {
    location: location
    prefix: prefix
    tags: tags
    enableRdpPublicIp: enableRdpPublicIp
    allowedRdpSource: allowedRdpSource
  }
}
module vm 'modules/vm.bicep' = {
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
module appGw 'modules/appgw.bicep' = {
  name: 'deploy-appgw'
  params: {
    location: location
    prefix: prefix
    tags: tags
    subnetId: network.outputs.appGwSubnetId
    backendIpAddresses: vm.outputs.privateIpAddresses
  }
}
module monitoring 'modules/monitoring.bicep' = {
  name: 'deploy-monitoring'
  params: {
    location: location
    prefix: prefix
    tags: tags
    vmIds: vm.outputs.vmIds
    vmNames: vm.outputs.vmNames
    appGwName: appGw.outputs.appGwName
    alertEmail: alertEmail
  }
}
module chaos 'modules/chaos.bicep' = {
  name: 'deploy-chaos'
  params: {
    location: location
    prefix: prefix
    tags: tags
    vmNames: vm.outputs.vmNames
    chaosIdentityClientId: vm.outputs.chaosIdentityClientId
    nsgName: network.outputs.nsgName
    appGwSubnetPrefix: network.outputs.appGwSubnetPrefix
    vmSubnetPrefix: network.outputs.vmSubnetPrefix
  }
  dependsOn: [
    monitoring
    chaosAgentReaderRoles
  ]
}
module sreAgent 'modules/sre-agent.bicep' = {
  name: 'deploy-sre-agent'
  params: {
    location: location
    prefix: prefix
    tags: tags
    agentName: sreAgentName
    accessLevel: sreAgentAccessLevel
    agentMode: sreAgentMode
    logAnalyticsWorkspaceId: monitoring.outputs.lawId
  }
}
// ===== VM-scoped RBAC ========================================================
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
resource targetNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' existing = {
  name: '${prefix}-nsg'
}
resource nsgExperimentRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(targetNsg.id, prefix, 'nsg-experiment', 'NetworkContributor')
  scope: targetNsg
  properties: {
    principalId: chaos.outputs.nsgExperimentPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4d97b98b-1d4f-4787-a291-c67834d212e7')
    principalType: 'ServicePrincipal'
  }
}

// ===== Deployer access =======================================================
resource sreAgentAdminRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, deployerPrincipalId, 'e79298df-d852-4c6d-84f9-5d13249d1e55')
  properties: {
    principalId: deployerPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'e79298df-d852-4c6d-84f9-5d13249d1e55')
    principalType: 'User'
  }
  dependsOn: [sreAgent]
}
resource deployerContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, deployerPrincipalId, 'b24988ac-6180-42a0-ab88-20f7382dd24c')
  properties: {
    principalId: deployerPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')
    principalType: 'User'
  }
  dependsOn: [sreAgent]
}

// ===== Outputs ===============================================================
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
output sreAgentName string = sreAgent.outputs.agentName
// Live reports (preview) are created from chat in the SRE Agent portal; there is no ARM resource for them.
output sreAgentPortalUrl string = sreAgent.outputs.agentPortalUrl
