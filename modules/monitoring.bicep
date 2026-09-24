// =============================================================================
// Module: monitoring.bicep
// Description: Windows VM and Application Gateway monitoring with Azure Monitor,
//              Log Analytics, performance counters, and IIS service-stop alerts.
// =============================================================================

@description('Azure region for deployment')
param location string

@description('Resource name prefix')
param prefix string

@description('Tags applied to every resource type that supports tags')
param tags object

@minLength(1)
@description('Target Windows VM names in this resource group; same order and length as vmIds')
param vmNames string[]

@minLength(1)
@description('Target Windows VM resource IDs; same order and length as vmNames')
param vmIds string[]

@description('Application Gateway name in this resource group')
param appGwName string

@description('Action Group email address for alert notifications')
param alertEmail string

// ---------------------------------------------------------------------------
// Existing resources (for scope bindings)
// ---------------------------------------------------------------------------
resource targetVms 'Microsoft.Compute/virtualMachines@2024-07-01' existing = [for vmName in vmNames: {
  name: vmName
}]

resource appGw 'Microsoft.Network/applicationGateways@2024-05-01' existing = {
  name: appGwName
}

// ---------------------------------------------------------------------------
// Log Analytics Workspace and built-in tables (before DCR/query validation)
// Tables, DCR associations, and diagnostic settings do not support tags.
// ---------------------------------------------------------------------------
resource law 'Microsoft.OperationalInsights/workspaces@2025-02-01' = {
  name: '${prefix}-law'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource eventTable 'Microsoft.OperationalInsights/workspaces/tables@2025-02-01' = {
  parent: law
  name: 'Event'
  properties: {
    retentionInDays: 30
  }
}

resource perfTable 'Microsoft.OperationalInsights/workspaces/tables@2025-02-01' = {
  parent: law
  name: 'Perf'
  properties: {
    retentionInDays: 30
  }
}

// ---------------------------------------------------------------------------
// Data Collection Rule – Windows performance and service-state events
// Collect all SCM 7036 events; service/state filtering belongs in the query,
// not in a localized rendered-message XPath.
// ---------------------------------------------------------------------------
resource dcr 'Microsoft.Insights/dataCollectionRules@2024-03-11' = {
  name: '${prefix}-dcr'
  location: location
  tags: tags
  kind: 'Windows'
  properties: {
    dataSources: {
      performanceCounters: [
        {
          name: 'windowsPerfCounters'
          streams: [
            'Microsoft-Perf'
          ]
          samplingFrequencyInSeconds: 10
          counterSpecifiers: [
            '\\Processor Information(_Total)\\% Processor Time'
            '\\Memory\\Available Bytes'
            '\\Memory\\% Committed Bytes In Use'
            '\\LogicalDisk(*)\\% Free Space'
            '\\LogicalDisk(*)\\Disk Reads/sec'
            '\\LogicalDisk(*)\\Disk Writes/sec'
            '\\LogicalDisk(*)\\Avg. Disk Queue Length'
          ]
        }
      ]
      windowsEventLogs: [
        {
          name: 'serviceStateEvents'
          streams: [
            'Microsoft-Event'
          ]
          xPathQueries: [
            'System!*[System[Provider[@Name=\'Service Control Manager\'] and (EventID=7036)]]'
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
          'Microsoft-Event'
        ]
        destinations: [
          'logAnalyticsDest'
        ]
      }
    ]
  }
  dependsOn: [
    eventTable
    perfTable
  ]
}

// ---------------------------------------------------------------------------
// Windows Azure Monitor Agent and association on every VM
// No user-assigned identity selector: AMA uses the system-assigned identity,
// even though the VM also has the shared user-assigned identity.
// https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-manage
// ---------------------------------------------------------------------------
resource amaExtensions 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = [for (vmName, i) in vmNames: {
  parent: targetVms[i]
  name: 'AzureMonitorWindowsAgent'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorWindowsAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
    settings: {
      authentication: {
        managedIdentity: {}
      }
    }
  }
}]

resource dcrAssociations 'Microsoft.Insights/dataCollectionRuleAssociations@2024-03-11' = [for (vmName, i) in vmNames: {
  name: '${prefix}-dcr-assoc'
  scope: targetVms[i]
  properties: {
    dataCollectionRuleId: dcr.id
  }
  dependsOn: [
    amaExtensions[i]
  ]
}]

// ---------------------------------------------------------------------------
// Application Gateway metrics only; no Access, Performance, or Firewall logs
// Diagnostic settings still use the supported 2021-05-01-preview API.
// ---------------------------------------------------------------------------
resource appGwDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${prefix}-appgw-metrics'
  scope: appGw
  properties: {
    workspaceId: law.id
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Action Group – email notification
// ---------------------------------------------------------------------------
resource actionGroup 'Microsoft.Insights/actionGroups@2024-10-01-preview' = {
  name: '${prefix}-ag'
  location: 'global'
  tags: tags
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
// VM metric alerts – five-minute averages, evaluated every minute
// Exact REST metric names:
// https://learn.microsoft.com/azure/azure-monitor/reference/supported-metrics/microsoft-compute-virtualmachines-metrics
// metricAlerts retains 2018-03-01: there is no newer stable API.
// ---------------------------------------------------------------------------
var vmMetricDefinitions = [
  {
    suffix: 'high-cpu'
    metricName: 'Percentage CPU'
    threshold: 80
    description: 'CPU average exceeds 80% over 5 minutes.'
  }
  {
    suffix: 'os-disk-iops'
    metricName: 'OS Disk IOPS Consumed Percentage'
    threshold: 90
    description: 'OS disk IOPS consumed average exceeds 90% over 5 minutes; requires a premium-storage-capable VM series.'
  }
  {
    suffix: 'os-disk-queue'
    metricName: 'OS Disk Queue Depth'
    threshold: 10
    description: 'OS disk queue depth average exceeds 10 over 5 minutes. Static demo threshold, not a universal production baseline.'
  }
  {
    suffix: 'cached-iops'
    metricName: 'VM Cached IOPS Consumed Percentage'
    threshold: 90
    description: 'VM cached IOPS consumed average exceeds 90% over 5 minutes. Reference alert for premium-storage-capable VMs; with caching None there may be no datapoints and this is not the uncached disk bottleneck signal.'
  }
]

var vmMetricAlerts = flatten(map(vmNames, (vmName, i) => map(vmMetricDefinitions, definition => {
  vmName: vmName
  vmId: vmIds[i]
  definition: definition
})))

resource vmAlerts 'Microsoft.Insights/metricAlerts@2018-03-01' = [for alert in vmMetricAlerts: {
  name: '${prefix}-${alert.vmName}-${alert.definition.suffix}-alert'
  location: 'global'
  tags: tags
  properties: {
    description: alert.definition.description
    severity: 2
    enabled: true
    scopes: [
      alert.vmId
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: alert.definition.suffix
          metricName: alert.definition.metricName
          metricNamespace: 'Microsoft.Compute/virtualMachines'
          operator: 'GreaterThan'
          threshold: alert.definition.threshold
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
}]

// ---------------------------------------------------------------------------
// Guest memory alert – Perf, not an unsupported platform memory metric
// Average Available Bytes < 200 MiB per VM over five minutes.
// ---------------------------------------------------------------------------
resource memoryAlert 'Microsoft.Insights/scheduledQueryRules@2025-01-01-preview' = {
  name: '${prefix}-low-memory-alert'
  location: location
  tags: tags
  kind: 'LogAlert'
  properties: {
    description: 'Guest available memory averages below 200 MiB for 5 minutes (Windows Perf).'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    scopes: [
      law.id
    ]
    targetResourceTypes: [
      'Microsoft.Compute/virtualMachines'
    ]
    criteria: {
      allOf: [
        {
          query: format('''
Perf
| where _ResourceId in~ (dynamic({0}))
| where ObjectName == "Memory" and CounterName == "Available Bytes"
| summarize AvailableBytes = avg(CounterValue) by _ResourceId, Computer
''', string(vmIds))
          timeAggregation: 'Average'
          metricMeasureColumn: 'AvailableBytes'
          resourceIdColumn: '_ResourceId'
          operator: 'LessThan'
          threshold: 209715200
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
  dependsOn: [
    perfTable
    dcrAssociations
  ]
}

// ---------------------------------------------------------------------------
// IIS stop alert – SCM 7036 param1 is the service DISPLAY name, not always
// W3SVC. Match param2=stopped, never running or unrelated service transitions.
// The exact rendered-message alternative covers agents omitting XML EventData.
// Service state/display-name values assume the lab's English Windows image.
// ---------------------------------------------------------------------------
resource iisStopAlert 'Microsoft.Insights/scheduledQueryRules@2025-01-01-preview' = {
  name: '${prefix}-iis-stop-alert'
  location: location
  tags: tags
  kind: 'LogAlert'
  properties: {
    description: 'IIS W3SVC entered the stopped state (System / Service Control Manager / event 7036).'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    scopes: [
      law.id
    ]
    targetResourceTypes: [
      'Microsoft.Compute/virtualMachines'
    ]
    criteria: {
      allOf: [
        {
          query: format('''
Event
| where _ResourceId in~ (dynamic({0}))
| where EventLog == "System" and Source == "Service Control Manager" and EventID == 7036
| extend ServiceName = extract(@'<Data\s+Name="param1"\s*>([^<]+)</Data>', 1, EventData),
         ServiceState = extract(@'<Data\s+Name="param2"\s*>([^<]+)</Data>', 1, EventData)
| where (ServiceName in~ ("W3SVC", "World Wide Web Publishing Service") and ServiceState =~ "stopped")
    or (isempty(ServiceName) and RenderedDescription matches regex @"^The (World Wide Web Publishing Service|W3SVC) service entered the stopped state\.\s*$")
| project TimeGenerated, _ResourceId, Computer, RenderedDescription
''', string(vmIds))
          timeAggregation: 'Count'
          resourceIdColumn: '_ResourceId'
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
  dependsOn: [
    eventTable
    dcrAssociations
  ]
}

// ---------------------------------------------------------------------------
// Application Gateway metric alerts – exact REST names and dimensions:
// https://learn.microsoft.com/azure/azure-monitor/reference/supported-metrics/microsoft-network-applicationgateways-metrics
// Both response metrics use HttpStatusGroup (not BackendHttpStatusGroup).
// ---------------------------------------------------------------------------
var appGwMetricDefinitions = [
  {
    suffix: 'unhealthy-host'
    metricName: 'UnhealthyHostCount'
    description: 'At least one unhealthy Application Gateway backend host on average over 5 minutes.'
    operator: 'GreaterThanOrEqual'
    threshold: 1
    aggregation: 'Average'
    dimensions: [
      {
        name: 'BackendSettingsPool'
        operator: 'Include'
        values: [
          '*'
        ]
      }
    ]
  }
  {
    suffix: 'frontend-5xx'
    metricName: 'ResponseStatus'
    description: 'Application Gateway returned at least one 5xx response in 5 minutes (Sum).'
    operator: 'GreaterThan'
    threshold: 0
    aggregation: 'Total'
    dimensions: [
      {
        name: 'HttpStatusGroup'
        operator: 'Include'
        values: [
          '5xx'
        ]
      }
    ]
  }
  {
    suffix: 'backend-5xx'
    metricName: 'BackendResponseStatus'
    description: 'Backend members returned at least one 5xx response in 5 minutes (Sum); excludes gateway-generated errors.'
    operator: 'GreaterThan'
    threshold: 0
    aggregation: 'Total'
    dimensions: [
      {
        name: 'HttpStatusGroup'
        operator: 'Include'
        values: [
          '5xx'
        ]
      }
    ]
  }
]

resource appGwAlerts 'Microsoft.Insights/metricAlerts@2018-03-01' = [for definition in appGwMetricDefinitions: {
  name: '${prefix}-appgw-${definition.suffix}-alert'
  location: 'global'
  tags: tags
  properties: {
    description: definition.description
    severity: 1
    enabled: true
    scopes: [
      appGw.id
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: definition.suffix
          metricName: definition.metricName
          metricNamespace: 'Microsoft.Network/applicationGateways'
          operator: definition.operator
          threshold: definition.threshold
          timeAggregation: definition.aggregation
          dimensions: definition.dimensions
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
}]

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output lawId string = law.id
output lawName string = law.name
output actionGroupId string = actionGroup.id
