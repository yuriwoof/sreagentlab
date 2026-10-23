// =============================================================================
// main.bicep
// Description: Windows IIS VMs, Application Gateway, monitoring, Chaos Studio,
//              and Azure SRE Agent for a disposable demonstration environment.
// =============================================================================

targetScope = 'resourceGroup'

// Verify service availability and subscription quota in Japan East before deployment.
@description('Azure region for all regional resources. Verify SRE Agent availability, VM quota, and SKU availability before deployment.')
param location string = 'japaneast'
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
param vmSize string = 'Standard_B2ms'
param enableRdpPublicIp bool = false
@description('Explicit restricted IPv4 CIDR when RDP is enabled; never use /0 or a wildcard')
param allowedRdpSource string = '127.0.0.1/32'
@description('Email address that receives Azure Monitor alert notifications.')
@minLength(3)
param alertEmail string
// A random default avoids recovering a soft-deleted workspace of the same name after the RG is recreated.
@description('Log Analytics workspace name. Defaults to a random suffix per deployment; set the existing name (output lawName) to redeploy into the same workspace.')
@minLength(4)
@maxLength(63)
param lawName string = '${prefix}-law-${take(uniqueString(newGuid()), 6)}'
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

// ===== Modules ===============================================================
module lab 'modules/lab.bicep' = {
  name: 'deploy-lab'
  params: {
    location: location
    prefix: prefix
    tags: tags
    adminUsername: adminUsername
    adminPassword: adminPassword
    vmSize: vmSize
    vmCount: vmCount
    enableRdpPublicIp: enableRdpPublicIp
    allowedRdpSource: allowedRdpSource
    alertEmail: alertEmail
    lawName: lawName
  }
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
    logAnalyticsWorkspaceId: lab.outputs.lawId
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
output vmNames string[] = lab.outputs.vmNames
output vmIds string[] = lab.outputs.vmIds
output appGwPublicIp string = lab.outputs.appGwPublicIp
output appGwName string = lab.outputs.appGwName
output appGwId string = lab.outputs.appGwId
output probeName string = lab.outputs.probeName
output nsgName string = lab.outputs.nsgName
output nsgId string = lab.outputs.nsgId
output appGwSubnetPrefix string = lab.outputs.appGwSubnetPrefix
output vmSubnetPrefix string = lab.outputs.vmSubnetPrefix
output lawName string = lab.outputs.lawName
output lawId string = lab.outputs.lawId
output experimentNames object = lab.outputs.experimentNames
output resourceGroupName string = lab.outputs.resourceGroupName
output sreAgentName string = sreAgent.outputs.agentName
// Live reports (preview) are created from chat in the SRE Agent portal; there is no ARM resource for them.
output sreAgentPortalUrl string = sreAgent.outputs.agentPortalUrl
