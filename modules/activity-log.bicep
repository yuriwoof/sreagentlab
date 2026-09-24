// =============================================================================
// Module: activity-log.bicep
// Description: Optional subscription Activity Log export to the lab workspace.
//              Deploy separately with subscription-level permissions.
// =============================================================================

targetScope = 'subscription'

@description('Resource ID of the destination Log Analytics workspace')
param lawId string

@description('Name of the subscription Activity Log diagnostic setting')
param diagnosticSettingName string

// Supported subscription categories and scope:
// https://learn.microsoft.com/azure/azure-monitor/data-collection/resource-manager-diagnostic-settings#diagnostic-setting-for-activity-log
// Diagnostic settings do not support tags. Export covers the entire subscription;
// SRE Agent live report / scheduled task queries must filter to the lab resource group.
resource activityLog 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: diagnosticSettingName
  scope: subscription()
  properties: {
    workspaceId: lawId
    logs: [for category in [
      'Administrative'
      'Policy'
      'Security'
      'ServiceHealth'
      'Alert'
      'Recommendation'
      'Autoscale'
      'ResourceHealth'
    ]: {
      category: category
      enabled: true
    }]
  }
}
