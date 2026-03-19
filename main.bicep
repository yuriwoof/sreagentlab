// =============================================================================
// main.bicep
// Description: Orchestrates the full SRE Agent Lab deployment.
//   - VNet / Subnet / NSG / Public IP
//   - Ubuntu Linux VM with nginx + stress-ng
//   - Log Analytics + Azure Monitor Agent + Metric Alerts
//   - Chaos Studio targets, capabilities, agent, experiments
//   - Azure SRE Agent (AI-powered reliability assistant)
// =============================================================================

targetScope = 'resourceGroup'

// ===== Parameters ============================================================

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Prefix used for all resource names')
param prefix string = 'srelab'

@description('VM admin username')
param adminUsername string = 'azureuser'

@description('SSH public key for VM authentication')
@secure()
param sshPublicKey string

@description('Email address for alert notifications')
param alertEmail string

@description('Allowed source IP for SSH access (CIDR notation). Use your public IP for security.')
param allowedSshSource string = '*'

@description('VM size (Standard_B2s is cost-effective for demos)')
param vmSize string = 'Standard_B2s'

@description('Name of the Azure SRE Agent')
param sreAgentName string = '${prefix}-agent'

@description('SRE Agent access level (High = Contributor, Low = Reader only)')
@allowed(['High', 'Low'])
param sreAgentAccessLevel string = 'High'

@description('SRE Agent mode (Review = semi-autonomous, Autonomous = fully automatic, ReadOnly = read only)')
@allowed(['Review', 'Autonomous', 'ReadOnly'])
param sreAgentMode string = 'Review'

@description('Object ID (principal ID) of the user deploying this template. Required for SRE Agent portal access.')
param deployerPrincipalId string

// ===== Modules ===============================================================

// 1) Networking
module network 'modules/network.bicep' = {
  name: 'deploy-network'
  params: {
    location: location
    prefix: prefix
    allowedSshSource: allowedSshSource
  }
}

// 2) Virtual Machine
module vm 'modules/vm.bicep' = {
  name: 'deploy-vm'
  params: {
    location: location
    prefix: prefix
    subnetId: network.outputs.subnetId
    publicIpId: network.outputs.publicIpId
    adminUsername: adminUsername
    sshPublicKey: sshPublicKey
    vmSize: vmSize
  }
}

// 3) Monitoring
module monitoring 'modules/monitoring.bicep' = {
  name: 'deploy-monitoring'
  params: {
    location: location
    prefix: prefix
    vmId: vm.outputs.vmId
    vmName: vm.outputs.vmName
    alertEmail: alertEmail
  }
}

// 4) Chaos Studio
module chaos 'modules/chaos.bicep' = {
  name: 'deploy-chaos'
  params: {
    location: location
    prefix: prefix
    vmName: vm.outputs.vmName
    chaosIdentityClientId: vm.outputs.chaosIdentityClientId
  }
  dependsOn: [
    monitoring          // Ensure monitoring agent is installed first
    chaosAgentReaderRole // Ensure Chaos Agent identity has Reader role before agent registers
  ]
}

// 5) SRE Agent
module sreAgent 'modules/sre-agent.bicep' = {
  name: 'deploy-sre-agent'
  params: {
    location: location
    prefix: prefix
    agentName: sreAgentName
    accessLevel: sreAgentAccessLevel
    agentMode: sreAgentMode
    logAnalyticsWorkspaceId: monitoring.outputs.lawId
  }
}

// ===== Role Assignment for Chaos Agent Identity ==============================
// The User-Assigned Managed Identity used by ChaosLinuxAgent needs Reader role
// on the target VM to register successfully with Chaos Studio.

resource chaosAgentReaderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, prefix, 'chaos-agent-identity', 'Reader')
  properties: {
    principalId: vm.outputs.chaosIdentityPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7') // Reader
    principalType: 'ServicePrincipal'
  }
}

// ===== Role Assignments for Chaos Experiments ================================
// Each Chaos experiment needs Reader role on the target VM.

resource cpuExpReaderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, prefix, 'cpu-experiment', 'Reader')
  properties: {
    principalId: chaos.outputs.cpuExperimentPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7') // Reader
    principalType: 'ServicePrincipal'
  }
}

resource memoryExpReaderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, prefix, 'memory-experiment', 'Reader')
  properties: {
    principalId: chaos.outputs.memoryExperimentPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7') // Reader
    principalType: 'ServicePrincipal'
  }
}

resource serviceStopExpReaderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, prefix, 'servicestop-experiment', 'Reader')
  properties: {
    principalId: chaos.outputs.serviceStopExperimentPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7') // Reader
    principalType: 'ServicePrincipal'
  }
}

// ===== Role Assignment for Deployer to Access SRE Agent =====================
// The deploying user needs "SRE Agent Administrator" role to manage incident
// response plans, create sub-agents, approve actions, and fully operate the agent.

resource sreAgentAdminRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, deployerPrincipalId, 'e79298df-d852-4c6d-84f9-5d13249d1e55')
  properties: {
    principalId: deployerPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'e79298df-d852-4c6d-84f9-5d13249d1e55') // SRE Agent Administrator
    principalType: 'User'
  }
  dependsOn: [
    sreAgent
  ]
}

// ===== Role Assignment for Deployer – Contributor ===========================
// Contributor role allows the deployer to configure and manage the SRE Agent.

resource deployerContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, deployerPrincipalId, 'b24988ac-6180-42a0-ab88-20f7382dd24c')
  properties: {
    principalId: deployerPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c') // Contributor
    principalType: 'User'
  }
  dependsOn: [
    sreAgent
  ]
}

// ===== Outputs ===============================================================

output vmPublicIp string = network.outputs.publicIpAddress
output vmName string = vm.outputs.vmName
output vmId string = vm.outputs.vmId
output lawName string = monitoring.outputs.lawName
output cpuExperimentName string = chaos.outputs.cpuExperimentName
output memoryExperimentName string = chaos.outputs.memoryExperimentName
output serviceStopExperimentName string = chaos.outputs.serviceStopExperimentName
output resourceGroupName string = resourceGroup().name
