// =============================================================================
// Module: dashboard.bicep
// Description: Read-only live workbook for VM, gateway, and chaos lab telemetry.
//              Metrics use Azure Monitor directly; guest data uses the workspace.
// =============================================================================

@description('Azure region for deployment')
param location string

@description('Resource name prefix')
param prefix string

@description('Tags applied to all supported resources')
param tags object = {}

@description('Resource IDs of the lab VMs; guest queries exclude all other VMs')
@minLength(1)
param vmIds string[]

@description('Resource ID of the lab Application Gateway')
param appGwId string

@description('Resource ID of the lab Log Analytics workspace')
param lawId string

// Workbook schema and the official Network Insights Application Gateway example:
// https://github.com/microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json
// https://github.com/microsoft/Application-Insights-Workbooks/blob/master/Workbooks/Network%20Insights/ApplicationGatewayWorkbooks/Network%20Insights%20ApplicationGateways%20Detailed/NetworkInsights-ApplicationGatewayMetrics.workbook
// MetricsItem/2.0: type 10; chartType 2 = line; aggregation 4 = average,
// 1 = sum; filter operator 0 = equals; metric IDs are namespace--REST-name.
var vmMetricDefinitions = [
  {
    name: 'Percentage CPU'
    title: 'CPU utilization (%) per VM'
    aggregation: 4
  }
  {
    name: 'OS Disk IOPS Consumed Percentage'
    title: 'OS disk IOPS consumed (%) per VM'
    aggregation: 4
  }
  {
    name: 'OS Disk Queue Depth'
    title: 'OS disk queue depth per VM'
    aggregation: 4
  }
  {
    name: 'Network In Total'
    title: 'Network in (bytes) per VM'
    aggregation: 1
  }
  {
    name: 'Network Out Total'
    title: 'Network out (bytes) per VM'
    aggregation: 1
  }
]

var vmMetricItems = [for metric in vmMetricDefinitions: {
  type: 10
  name: 'vm-${metric.name}'
  content: {
    version: 'MetricsItem/2.0'
    chartId: guid(resourceGroup().id, prefix, metric.name)
    size: 0
    chartType: 2
    resourceType: 'microsoft.compute/virtualmachines'
    resourceIds: vmIds
    resourceLimit: length(vmIds)
    timeContext: {
      durationMs: 3600000
    }
    timeContextFromParameter: 'TimeRange'
    title: metric.title
    metrics: [
      {
        namespace: 'microsoft.compute/virtualmachines'
        metric: 'microsoft.compute/virtualmachines--${metric.name}'
        aggregation: metric.aggregation
      }
    ]
  }
}]

var appGwMetricDefinitions = [
  {
    name: 'HealthyHostCount'
    title: 'Application Gateway healthy backend hosts'
    aggregation: 4
    filters: []
  }
  {
    name: 'UnhealthyHostCount'
    title: 'Application Gateway unhealthy backend hosts'
    aggregation: 4
    filters: []
  }
  {
    name: 'TotalRequests'
    title: 'Application Gateway total requests'
    aggregation: 1
    filters: []
  }
  {
    name: 'ResponseStatus'
    title: 'Application Gateway frontend 5xx responses'
    aggregation: 1
    filters: [
      {
        key: 'HttpStatusGroup'
        operator: 0
        values: [
          '5xx'
        ]
      }
    ]
  }
  {
    name: 'BackendResponseStatus'
    title: 'Application Gateway backend 5xx responses'
    aggregation: 1
    filters: [
      {
        key: 'HttpStatusGroup'
        operator: 0
        values: [
          '5xx'
        ]
      }
    ]
  }
]

var appGwMetricItems = [for metric in appGwMetricDefinitions: {
  type: 10
  name: 'appgw-${metric.name}'
  content: {
    version: 'MetricsItem/2.0'
    chartId: guid(resourceGroup().id, prefix, metric.name)
    size: 0
    chartType: 2
    resourceType: 'microsoft.network/applicationgateways'
    resourceIds: [
      appGwId
    ]
    timeContext: {
      durationMs: 3600000
    }
    timeContextFromParameter: 'TimeRange'
    title: metric.title
    metrics: [
      {
        namespace: 'microsoft.network/applicationgateways'
        metric: 'microsoft.network/applicationgateways--${metric.name}'
        aggregation: metric.aggregation
        filters: metric.filters
      }
    ]
  }
}]

var availableMemoryQuery = format('''
Perf
| where TimeGenerated {{TimeRange}}
| where _ResourceId in~ (dynamic({0}))
| where ObjectName == "Memory" and CounterName == "Available Bytes"
| summarize AvailableMemoryMiB = avg(CounterValue) / 1048576.0 by Computer, bin(TimeGenerated, 1m)
| order by TimeGenerated asc
''', string(vmIds))

var serviceStopQuery = format('''
Event
| where TimeGenerated {{TimeRange}}
| where _ResourceId in~ (dynamic({0}))
| where EventLog == "System" and Source == "Service Control Manager" and EventID == 7036
| extend ServiceName = extract(@'<Data\s+Name="param1"\s*>([^<]+)</Data>', 1, EventData),
         ServiceState = extract(@'<Data\s+Name="param2"\s*>([^<]+)</Data>', 1, EventData)
| where (ServiceName in~ ("W3SVC", "World Wide Web Publishing Service") and ServiceState =~ "stopped")
    or (isempty(ServiceName) and RenderedDescription matches regex @"^The (World Wide Web Publishing Service|W3SVC) service entered the stopped state\.\s*$")
| project TimeGenerated, Computer, ServiceName, ServiceState, RenderedDescription, _ResourceId
| order by TimeGenerated desc
''', string(vmIds))

// Experiments belong to the module's lab resource group; filtering the complete
// resource ID prefix avoids similarly named groups in other subscriptions.
var chaosStartQuery = format('''
AzureActivity
| where TimeGenerated {{TimeRange}}
| where OperationNameValue =~ "Microsoft.Chaos/experiments/start/action"
| where ResourceId startswith "{0}/providers/Microsoft.Chaos/experiments/"
| project TimeGenerated, ResourceGroup, ResourceId, ActivityStatusValue, Caller, CorrelationId
| order by TimeGenerated desc
''', resourceGroup().id)

var logItems = [
  {
    type: 3
    name: 'available-memory'
    content: {
      version: 'KqlItem/1.0'
      title: 'Available memory (MiB) per VM / Computer'
      query: availableMemoryQuery
      size: 0
      queryType: 0
      resourceType: 'microsoft.operationalinsights/workspaces'
      crossComponentResources: [
        lawId
      ]
      timeContextFromParameter: 'TimeRange'
      visualization: 'timechart'
    }
  }
  {
    type: 3
    name: 'chaos-start-history'
    content: {
      version: 'KqlItem/1.0'
      title: 'Chaos experiment start history (lab resource group)'
      query: chaosStartQuery
      size: 0
      queryType: 0
      resourceType: 'microsoft.operationalinsights/workspaces'
      crossComponentResources: [
        lawId
      ]
      timeContextFromParameter: 'TimeRange'
      visualization: 'table'
    }
  }
  {
    type: 3
    name: 'w3svc-stop-history'
    content: {
      version: 'KqlItem/1.0'
      title: 'IIS W3SVC stopped — Service Control Manager event 7036'
      query: serviceStopQuery
      size: 0
      queryType: 0
      resourceType: 'microsoft.operationalinsights/workspaces'
      crossComponentResources: [
        lawId
      ]
      timeContextFromParameter: 'TimeRange'
      visualization: 'table'
    }
  }
]

// Auto-refresh is deliberately not invented as a serialized refreshSettings
// property: the public schema/examples do not define it, and Microsoft documents
// that the interval is session-only and is NOT saved with a workbook.
// https://learn.microsoft.com/azure/azure-monitor/visualize/workbooks-manage#set-up-auto-refresh
var workbookData = {
  version: 'Notebook/1.0'
  '$schema': 'https://github.com/microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json'
  items: concat([
    {
      type: 1
      name: 'live-report-notes'
      content: {
        json: '''
# Live lab report

The default time range is **Last 1 hour**. In read mode, select **Auto refresh → 1 minute** each time you open the workbook. Azure Workbooks does not persist this interval. Refreshing only reads telemetry; it does not start experiments, restart services, or create scheduled automation.

VM and Application Gateway charts query **Azure Monitor platform metrics directly**, not `AzureMetrics`. Guest available memory and IIS events come from the monitoring module's DCR and Log Analytics workspace. OS disk IOPS percentage requires a VM SKU supporting premium storage; missing metrics are not zero. Application Gateway counters need traffic.

**ActivityLog requires the optional `enable-activity-log.sh` step** (subscription-level permissions). Without the export, `AzureActivity` may be absent or empty. Export is subscription-wide, while the history below is restricted to Chaos experiments in this lab resource group. Only activity ingested after enabling export is available.

**Allow for ingestion delay**: AMA `Perf` / `Event` data and Activity Log export can arrive several minutes after an action. A one-minute refresh does not guarantee one-minute ingestion. An empty panel does not prove that no fault occurred. W3SVC stop detection expects English Windows service name/state text (`World Wide Web Publishing Service` / `stopped`).
'''
      }
    }
    {
      type: 9
      name: 'time-range'
      content: {
        version: 'KqlParameterItem/1.0'
        style: 'pills'
        parameters: [
          {
            id: guid(resourceGroup().id, prefix, 'time-range')
            version: 'KqlParameterItem/1.0'
            name: 'TimeRange'
            label: 'Time range'
            type: 4
            isRequired: true
            value: {
              durationMs: 3600000
            }
            typeSettings: {
              selectableValues: [
                {
                  durationMs: 900000
                }
                {
                  durationMs: 3600000
                }
                {
                  durationMs: 14400000
                }
                {
                  durationMs: 86400000
                }
              ]
              allowCustom: true
            }
          }
        ]
      }
    }
  ], vmMetricItems, appGwMetricItems, logItems)
  fallbackResourceIds: [
    lawId
  ]
}

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: guid(resourceGroup().id, prefix, 'workbook')
  location: location
  tags: union(tags, {
    displayName: '${prefix}-live-report'
  })
  kind: 'shared'
  properties: {
    displayName: '${prefix}-live-report'
    version: '1.0'
    category: 'workbook'
    sourceId: lawId
    serializedData: string(workbookData)
  }
}

output workbookId string = workbook.id
output workbookUrl string = 'https://portal.azure.com/#@${tenant().tenantId}/resource${workbook.id}/workbook'
