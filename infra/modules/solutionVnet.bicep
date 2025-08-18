/**
  Virtual Network with three subnets for solution needs (AVM)
  - Subnets: Flex Function Integration, App/Logic App Integration, Private Endpoints
  - Integration subnets delegated to Microsoft.Web/serverFarms (App Service VNet Integration)
  - Private Endpoint subnet has network policies disabled for PE

  Uses AVM virtual-network module.
*/

targetScope = 'resourceGroup'

@description('VNet name')
param name string

@description('Azure location')
param location string = resourceGroup().location

@description('VNet address space (CIDR)')
param addressSpace string

@description('Flex Functions integration subnet name')
param flexIntegrationSubnetName string

@description('Flex Functions integration subnet CIDR')
param flexIntegrationSubnetPrefix string

@description('App/Logic App integration subnet name')
param appIntegrationSubnetName string

@description('App/Logic App integration subnet CIDR')
param appIntegrationSubnetPrefix string

@description('Private Endpoints subnet name')
param peSubnetName string

@description('Private Endpoints subnet CIDR')
param peSubnetPrefix string

@description('Tags to apply')
param tags object = {}

module vnet 'br/public:avm/res/network/virtual-network:0.7.0' = {
  name: 'vnet-${uniqueString(resourceGroup().id, name)}'
  params: {
    name: name
    location: location
    addressPrefixes: [ addressSpace ]
    tags: tags
    subnets: [
      {
        name: flexIntegrationSubnetName
        addressPrefix: flexIntegrationSubnetPrefix
        // Azure Functions Flex Consumption requires delegation to Microsoft.App/environments
        delegation: 'Microsoft.App/environments'
      }
      {
        name: appIntegrationSubnetName
        addressPrefix: appIntegrationSubnetPrefix
        delegation: 'Microsoft.Web/serverFarms'
      }
      {
        name: peSubnetName
        addressPrefix: peSubnetPrefix
        privateEndpointNetworkPolicies: 'Disabled'
        privateLinkServiceNetworkPolicies: 'Enabled'
      }
    ]
  }
}

// Outputs
var vnetId = vnet.outputs.resourceId

output vnetIdOut string = vnetId
output flexIntegrationSubnetId string = '${vnetId}/subnets/${flexIntegrationSubnetName}'
output appIntegrationSubnetId string = '${vnetId}/subnets/${appIntegrationSubnetName}'
output peSubnetId string = '${vnetId}/subnets/${peSubnetName}'
