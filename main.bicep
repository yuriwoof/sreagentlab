// =============================================================================
// main.bicep
// Description: Orchestrates the full SRE Agent Lab deployment.
//   - VNet / Subnet / NSG / Public IP
//   - Ubuntu Linux VM with nginx + stress-ng
//   - Log Analytics + Azure Monitor Agent + Metric Alerts
//   - Chaos Studio targets, capabilities, agent, experiments
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

// ===== Outputs ===============================================================

output vmPublicIp string = network.outputs.publicIpAddress
output vmName string = vm.outputs.vmName
output vmId string = vm.outputs.vmId
output lawName string = monitoring.outputs.lawName
output cpuExperimentName string = chaos.outputs.cpuExperimentName
output memoryExperimentName string = chaos.outputs.memoryExperimentName
output serviceStopExperimentName string = chaos.outputs.serviceStopExperimentName
output resourceGroupName string = resourceGroup().name
