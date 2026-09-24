// =============================================================================
// Module: network.bicep
// Description: Isolated VM and Application Gateway subnets, NSGs, and explicit
//              outbound connectivity for the Windows web workload.
// =============================================================================

@description('Azure region for deployment')
param location string

@description('Resource name prefix')
param prefix string

@description('Tags applied to all supported resources')
param tags object = {}

@description('Enable public IPs and restricted inbound RDP for the VMs')
param enableRdpPublicIp bool = false

@description('Restricted IPv4 CIDR for optional RDP; deploy.sh rejects wildcard and /0 input')
@minLength(9)
@maxLength(18)
param allowedRdpSource string = '127.0.0.1/32'

var vmSubnetAddressPrefix = '10.0.1.0/24'
var appGwSubnetAddressPrefix = '10.0.2.0/24'

// ---------------------------------------------------------------------------
// Network Security Groups (priority 100 is reserved for Chaos Studio)
// ---------------------------------------------------------------------------
resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${prefix}-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: concat([
      {
        name: 'AllowHTTPFromApplicationGateway'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: appGwSubnetAddressPrefix
          destinationAddressPrefix: vmSubnetAddressPrefix
        }
      }
      {
        name: 'DenyOtherHTTP'
        properties: {
          priority: 210
          direction: 'Inbound'
          access: 'Deny'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'DenyOtherRDP'
        properties: {
          priority: 310
          direction: 'Inbound'
          access: 'Deny'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3389'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ], enableRdpPublicIp ? [
      {
        name: 'AllowRestrictedRDP'
        properties: {
          priority: 300
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3389'
          sourceAddressPrefix: allowedRdpSource
          destinationAddressPrefix: vmSubnetAddressPrefix
        }
      }
    ] : [])
  }
}

resource appGwNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${prefix}-appgw-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowInternetHTTPHTTPS'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRanges: [
            '80'
            '443'
          ]
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowGatewayManager'
        properties: {
          priority: 210
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '65200-65535'
          sourceAddressPrefix: 'GatewayManager'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowAzureLoadBalancer'
        properties: {
          priority: 220
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Explicit VM outbound connectivity (not an inbound VM public IP)
// ---------------------------------------------------------------------------
resource natPublicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${prefix}-nat-pip'
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

resource natGateway 'Microsoft.Network/natGateways@2024-05-01' = {
  name: '${prefix}-nat'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [
      {
        id: natPublicIp.id
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Virtual Network & dedicated subnets
// ---------------------------------------------------------------------------
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: '${prefix}-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: '${prefix}-snet-vm'
        properties: {
          addressPrefix: vmSubnetAddressPrefix
          defaultOutboundAccess: false
          networkSecurityGroup: {
            id: nsg.id
          }
          natGateway: {
            id: natGateway.id
          }
        }
      }
      {
        name: '${prefix}-snet-appgw'
        properties: {
          addressPrefix: appGwSubnetAddressPrefix
          networkSecurityGroup: {
            id: appGwNsg.id
          }
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output subnetId string = vnet.properties.subnets[0].id
output appGwSubnetId string = vnet.properties.subnets[1].id
output appGwSubnetPrefix string = appGwSubnetAddressPrefix
output vmSubnetPrefix string = vmSubnetAddressPrefix
output nsgId string = nsg.id
output nsgName string = nsg.name
output vnetId string = vnet.id
