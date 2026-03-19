// =============================================================================
// Module: sre-agent.bicep
// Description: Azure SRE Agent with Application Insights, Managed Identity,
//              and role assignments for monitoring target resource groups.
// =============================================================================

@description('Azure region for deployment')
param location string

@description('Resource name prefix')
param prefix string

@description('SRE Agent name')
param agentName string

@description('Access level for the SRE Agent (High = Contributor, Low = Reader)')
@allowed(['High', 'Low'])
param accessLevel string = 'High'

@description('Agent mode (Review = semi-autonomous, Autonomous = fully automatic, ReadOnly = read only)')
@allowed(['Review', 'Autonomous', 'ReadOnly'])
param agentMode string = 'Review'

@description('Resource ID of the existing Log Analytics Workspace from monitoring module')
param logAnalyticsWorkspaceId string

// ---------------------------------------------------------------------------
// User-Assigned Managed Identity for SRE Agent
// ---------------------------------------------------------------------------
resource sreIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${prefix}-sre-identity'
  location: location
}

// ---------------------------------------------------------------------------
// Application Insights (linked to existing Log Analytics Workspace)
// ---------------------------------------------------------------------------
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${prefix}-sre-appinsights'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    Request_Source: 'SreAgent'
    WorkspaceResourceId: logAnalyticsWorkspaceId
  }
}

// ---------------------------------------------------------------------------
// Action Group for Smart Detection alerts
// ---------------------------------------------------------------------------
resource smartDetectionActionGroup 'Microsoft.Insights/actionGroups@2023-09-01-preview' = {
  name: '${prefix}-sre-smart-detection-ag'
  location: 'global'
  properties: {
    groupShortName: 'SmartDetect'
    enabled: true
    armRoleReceivers: [
      {
        name: 'Monitoring Contributor'
        roleId: '749f88d5-cbae-40b8-bcfc-e573ddc772fa'
        useCommonAlertSchema: true
      }
      {
        name: 'Monitoring Reader'
        roleId: '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
        useCommonAlertSchema: true
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Smart Detector Alert Rule – Failure Anomalies
// ---------------------------------------------------------------------------
resource failureAnomaliesDetector 'Microsoft.AlertsManagement/smartDetectorAlertRules@2021-04-01' = {
  name: 'Failure Anomalies - ${prefix}-sre-appinsights'
  location: 'global'
  properties: {
    description: 'Failure Anomalies notifies you of an unusual rise in the rate of failed HTTP requests or dependency calls.'
    state: 'Enabled'
    severity: 'Sev3'
    frequency: 'PT1M'
    detector: {
      id: 'FailureAnomaliesDetector'
    }
    scope: [
      appInsights.id
    ]
    actionGroups: {
      groupIds: [
        smartDetectionActionGroup.id
      ]
    }
  }
}

// ---------------------------------------------------------------------------
// Role Assignments – SRE Agent identity on the deployment resource group
// ---------------------------------------------------------------------------

// Log Analytics Reader
resource logAnalyticsReaderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, sreIdentity.id, '92aaf0da-9dab-42b6-94a3-d43ce8d16293')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '92aaf0da-9dab-42b6-94a3-d43ce8d16293') // Log Analytics Reader
    principalId: sreIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Reader
resource readerRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, sreIdentity.id, 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7') // Reader
    principalId: sreIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Contributor (High access level only)
resource contributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (accessLevel == 'High') {
  name: guid(resourceGroup().id, sreIdentity.id, 'b24988ac-6180-42a0-ab88-20f7382dd24c')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c') // Contributor
    principalId: sreIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// SRE Agent
// ---------------------------------------------------------------------------
#disable-next-line BCP081
resource sreAgent 'Microsoft.App/agents@2025-05-01-preview' = {
  name: agentName
  location: location
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${sreIdentity.id}': {}
    }
  }
  properties: {
    knowledgeGraphConfiguration: {
      identity: sreIdentity.id
      managedResources: [
        resourceGroup().id
      ]
    }
    actionConfiguration: {
      accessLevel: accessLevel
      identity: sreIdentity.id
      mode: agentMode
    }
    logConfiguration: {
      applicationInsightsConfiguration: {
        appId: appInsights.properties.AppId
        connectionString: appInsights.properties.ConnectionString
      }
    }
  }
  dependsOn: [
    logAnalyticsReaderRole
    readerRole
    contributorRole
  ]
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output agentId string = sreAgent.id
output agentName string = sreAgent.name
output agentPortalUrl string = 'https://portal.azure.com/#view/Microsoft_Azure_PaasServerless/AgentFrameBlade.ReactView/id/${replace(sreAgent.id, '/', '%2F')}'
output sreIdentityId string = sreIdentity.id
output sreIdentityPrincipalId string = sreIdentity.properties.principalId
