// =============================================================================
// Module: monitoring.bicep
// Description: Log Analytics Workspace, VM Insights (Azure Monitor Agent),
//              and Metric Alert for high CPU usage.
// =============================================================================

@description('Azure region for deployment')
param location string

@description('Resource name prefix')
param prefix string

@description('Target VM resource ID')
param vmId string

@description('Target VM name')
param vmName string

@description('Action Group email address for alert notifications')
param alertEmail string

// ---------------------------------------------------------------------------
// Existing VM reference (for scope bindings)
// ---------------------------------------------------------------------------
resource targetVm 'Microsoft.Compute/virtualMachines@2024-07-01' existing = {
  name: vmName
}

// ---------------------------------------------------------------------------
// Log Analytics Workspace
// ---------------------------------------------------------------------------
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${prefix}-law'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// ---------------------------------------------------------------------------
// Ensure built-in Syslog table is provisioned before DCR references it
// ---------------------------------------------------------------------------
resource syslogTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: law
  name: 'Syslog'
  properties: {
    retentionInDays: 30
  }
}

// ---------------------------------------------------------------------------
// Data Collection Rule – perf counters & syslog
// ---------------------------------------------------------------------------
resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: '${prefix}-dcr'
  location: location
  properties: {
    dataSources: {
      performanceCounters: [
        {
          name: 'perfCounters'
          streams: [
            'Microsoft-Perf'
          ]
          samplingFrequencyInSeconds: 10
          counterSpecifiers: [
            '\\Processor Information(_Total)\\% Processor Time'
            '\\Memory\\% Committed Bytes In Use'
            '\\Memory\\Available Bytes'
            '\\LogicalDisk(_Total)\\% Free Space'
          ]
        }
      ]
      syslog: [
        {
          name: 'syslog'
          streams: [
            'Microsoft-Syslog'
          ]
          facilityNames: [
            'auth'
            'daemon'
            'kern'
            'syslog'
          ]
          logLevels: [
            'Warning'
            'Error'
            'Critical'
            'Alert'
            'Emergency'
          ]
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: law.id
          name: 'logAnalyticsDest'
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Microsoft-Perf'
        ]
        destinations: [
          'logAnalyticsDest'
        ]
      }
      {
        streams: [
          'Microsoft-Syslog'
        ]
        destinations: [
          'logAnalyticsDest'
        ]
      }
    ]
  }
  dependsOn: [
    syslogTable
  ]
}

// ---------------------------------------------------------------------------
// Azure Monitor Agent Extension
// ---------------------------------------------------------------------------
resource amaExtension 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: targetVm
  name: 'AzureMonitorLinuxAgent'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorLinuxAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
  dependsOn: [
    dcr
  ]
}

// ---------------------------------------------------------------------------
// Data Collection Rule Association
// ---------------------------------------------------------------------------
resource dcrAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
  name: '${prefix}-dcr-assoc'
  scope: targetVm
  properties: {
    dataCollectionRuleId: dcr.id
  }
  dependsOn: [
    amaExtension
  ]
}

// ---------------------------------------------------------------------------
// Action Group – email notification
// ---------------------------------------------------------------------------
resource actionGroup 'Microsoft.Insights/actionGroups@2023-09-01-preview' = {
  name: '${prefix}-ag'
  location: 'global'
  properties: {
    groupShortName: 'SREDemo'
    enabled: true
    emailReceivers: [
      {
        name: 'AdminEmail'
        emailAddress: alertEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Metric Alert – CPU > 80 % for 5 minutes
// ---------------------------------------------------------------------------
resource cpuAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${prefix}-high-cpu-alert'
  location: 'global'
  properties: {
    description: 'Alert when VM CPU exceeds 80% for 5 minutes (Chaos Studio demo)'
    severity: 2
    enabled: true
    scopes: [
      vmId
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'HighCPU'
          metricName: 'Percentage CPU'
          metricNamespace: 'Microsoft.Compute/virtualMachines'
          operator: 'GreaterThan'
          threshold: 80
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Metric Alert – Memory Pressure > 90 %
// ---------------------------------------------------------------------------
resource memoryAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${prefix}-high-memory-alert'
  location: 'global'
  properties: {
    description: 'Alert when VM available memory is low (Chaos Studio demo)'
    severity: 2
    enabled: true
    scopes: [
      vmId
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'HighMemory'
          metricName: 'Available Memory Bytes'
          metricNamespace: 'Microsoft.Compute/virtualMachines'
          operator: 'LessThan'
          threshold: 209715200  // 200 MB
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output lawId string = law.id
output lawName string = law.name
output actionGroupId string = actionGroup.id
output cpuAlertId string = cpuAlert.id
