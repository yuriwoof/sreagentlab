// Reference deployment: lab infrastructure only. The existing SRE Agent is not modified.
targetScope = 'resourceGroup'

@description('Azure region for lab resources. Verify VM quota and SKU availability before deployment.')
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
@description('Log Analytics workspace name. Defaults to a random suffix per deployment; set the existing name (output lawName) to redeploy into the same workspace.')
@minLength(4)
@maxLength(63)
param lawName string = '${prefix}-law-${take(uniqueString(newGuid()), 6)}'

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
