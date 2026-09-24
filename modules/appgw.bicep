// =============================================================================
// Module: appgw.bicep
// Description: Public Application Gateway v2 routing HTTP to private IIS VMs.
// =============================================================================

@description('Azure region for deployment')
param location string

@description('Resource name prefix')
param prefix string

@description('Tags applied to all supported resources')
param tags object = {}

@description('Dedicated Application Gateway subnet resource ID')
param subnetId string

@description('Private IP addresses of the IIS backend VMs')
@minLength(1)
param backendIpAddresses string[]

var gatewayName = '${prefix}-appgw'
var gatewayId = resourceId('Microsoft.Network/applicationGateways', gatewayName)
var healthProbeName = 'iis-health'

// ---------------------------------------------------------------------------
// Public frontend
// ---------------------------------------------------------------------------
resource publicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${prefix}-appgw-pip'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

// ---------------------------------------------------------------------------
// Application Gateway
// ---------------------------------------------------------------------------
resource appGw 'Microsoft.Network/applicationGateways@2024-05-01' = {
  name: gatewayName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'Standard_v2'
      tier: 'Standard_v2'
      capacity: 1
    }
    gatewayIPConfigurations: [
      {
        name: 'gateway-ip'
        properties: {
          subnet: {
            id: subnetId
          }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'public-frontend'
        properties: {
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
    frontendPorts: [
      {
        name: 'http'
        properties: {
          port: 80
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'iis-pool'
        properties: {
          backendAddresses: [for ip in backendIpAddresses: {
            ipAddress: ip
          }]
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'iis-http'
        properties: {
          port: 80
          protocol: 'Http'
          cookieBasedAffinity: 'Disabled'
          requestTimeout: 30
          probe: {
            id: '${gatewayId}/probes/${healthProbeName}'
          }
        }
      }
    ]
    probes: [
      {
        name: healthProbeName
        properties: {
          protocol: 'Http'
          host: '127.0.0.1'
          path: '/health.htm'
          interval: 15
          timeout: 10
          unhealthyThreshold: 2
          match: {
            statusCodes: [
              '200'
            ]
          }
        }
      }
    ]
    httpListeners: [
      {
        name: 'http-listener'
        properties: {
          frontendIPConfiguration: {
            id: '${gatewayId}/frontendIPConfigurations/public-frontend'
          }
          frontendPort: {
            id: '${gatewayId}/frontendPorts/http'
          }
          protocol: 'Http'
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'http-rule'
        properties: {
          priority: 100
          ruleType: 'Basic'
          httpListener: {
            id: '${gatewayId}/httpListeners/http-listener'
          }
          backendAddressPool: {
            id: '${gatewayId}/backendAddressPools/iis-pool'
          }
          backendHttpSettings: {
            id: '${gatewayId}/backendHttpSettingsCollection/iis-http'
          }
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output appGwId string = appGw.id
output appGwName string = appGw.name
output appGwPublicIp string = publicIp.properties.ipAddress
output probeName string = healthProbeName
