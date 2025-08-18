/**
  Private Endpoint for an existing Azure OpenAI resource (AVM)
  - Creates a Private Endpoint in the provided subnet
  - Attaches a Private DNS zone group for Cognitive Services (privatelink.cognitiveservices.*)
  - Optimized to work with already-provisioned Microsoft.CognitiveServices/accounts (Azure OpenAI)

  Docs:
  - Azure OpenAI networking: https://learn.microsoft.com/azure/ai-services/openai/how-to/private-networking
  - Private Endpoint + DNS for Cognitive Services: https://learn.microsoft.com/azure/ai-services/cognitive-services-virtual-networks
  - AVM index: https://azure.github.io/Azure-Verified-Modules/indexes/bicep/bicep-resource-modules/
*/

targetScope = 'resourceGroup'

@description('The resource ID of the existing Azure OpenAI (Cognitive Services) resource')
param existingOpenAIResourceId string

@description('Optional name for the private endpoint; if empty, it will be generated from the OpenAI account name')
param privateEndpointName string = ''

@description('The resource ID of the subnet where the private endpoint will be created')
param subnetResourceId string

@description('The resource ID of the existing Cognitive Services private DNS zone (privatelink.cognitiveservices.*). If empty and createDnsZone=true, a zone will be created and linked to the VNet')
param privateDnsZoneId string = ''

@description('Set to true to create the Cognitive Services Private DNS zone and link it to a VNet when no zone ID is provided')
param createDnsZone bool = false

@description('VNet resource ID to link the Private DNS zone (required when createDnsZone=true and no zone ID provided)')
param dnsZoneVnetResourceId string = ''

@description('Private DNS zone name for Cognitive Services')
param dnsZoneName string = 'privatelink.cognitiveservices.azure.com'

@description('The location for the private endpoint resources')
param location string = resourceGroup().location

@description('Tags to apply to the private endpoint')
param tags object = {}

// Derive OpenAI account name and a stable PE name when not provided
var openAIAccountName = last(split(existingOpenAIResourceId, '/'))
var effectivePeName = !empty(privateEndpointName) ? privateEndpointName : 'pe-${toLower(openAIAccountName)}'

// Optionally create Private DNS zone and VNet link using AVM
module dns 'br/public:avm/res/network/private-dns-zone:0.7.0' = if (createDnsZone && empty(privateDnsZoneId)) {
  name: 'dns-cogsvc-${uniqueString(resourceGroup().id, openAIAccountName)}'
  params: {
    name: dnsZoneName
    tags: tags
    virtualNetworkLinks: [
      {
        name: 'link-cogsvc-${take(uniqueString(resourceGroup().id, openAIAccountName), 8)}'
        virtualNetworkResourceId: dnsZoneVnetResourceId
        registrationEnabled: false
      }
    ]
  }
}

var effectiveDnsZoneId = !empty(privateDnsZoneId) ? privateDnsZoneId : resourceId('Microsoft.Network/privateDnsZones', dnsZoneName)

// Create private endpoint for existing Azure OpenAI resource using AVM module
module privateEndpoint 'br/public:avm/res/network/private-endpoint:0.11.0' = {
  name: 'oai-pe-${uniqueString(resourceGroup().id, effectivePeName)}'
  params: {
    name: effectivePeName
    location: location
    tags: tags
    subnetResourceId: subnetResourceId
    privateLinkServiceConnections: [
      {
        name: effectivePeName
        properties: {
          privateLinkServiceId: existingOpenAIResourceId
          groupIds: [ 'account' ]
          requestMessage: 'Please approve this private endpoint connection for Azure OpenAI'
        }
      }
    ]
    privateDnsZoneGroup: {
      name: 'default'
      privateDnsZoneGroupConfigs: [
        {
          name: 'cognitive-services'
          privateDnsZoneResourceId: effectiveDnsZoneId
        }
      ]
    }
  }
}

@description('The resource ID of the created private endpoint')
output privateEndpointResourceId string = resourceId('Microsoft.Network/privateEndpoints', effectivePeName)

@description('The name of the created private endpoint')
output name string = effectivePeName
