/**
  Azure AI Search service with Private Endpoint and Private DNS (AVM)
  - System-assigned managed identity
  - Local auth disabled (RBAC only)
  - Public network access disabled
  - Private Endpoint to provided subnet + DNS zone group
  - Optional: create Private DNS zone (privatelink.search.*) and VNet link

  Docs:
  - Azure AI Search PE + DNS: https://learn.microsoft.com/azure/search/search-security-networking
  - AVM index: https://azure.github.io/Azure-Verified-Modules/indexes/bicep/bicep-resource-modules/
*/

targetScope = 'resourceGroup'

@description('Azure AI Search service name')
param name string

@description('Azure location')
param location string = resourceGroup().location

@description('Subnet resource ID for Private Endpoint')
param peSubnetId string

@description('Existing Private DNS zone resource ID for privatelink.search.*. Leave empty to create when createDnsZone = true')
param searchPrivateDnsZoneResourceId string = ''

@description('Set to true to create the Private DNS zone and link it to a VNet when no zone ID is provided')
param createDnsZone bool = false

@description('Private DNS zone name for Search (default public cloud)')
param searchDnsZoneName string = 'privatelink.search.windows.net'

@description('VNet resource ID to link the Private DNS zone (required when createDnsZone = true and no zone ID provided)')
param dnsZoneVnetResourceId string = ''

@description('Tags to apply')
param tags object = {}

@description('Azure AI Search service SKU - must be Basic or higher for private endpoints')
@allowed([ 'basic', 'standard', 'standard2', 'standard3' ])
param sku string = 'standard'

@description('Number of replicas for high availability')
@minValue(1)
@maxValue(12)
param replicaCount int = 1

@description('Number of partitions for scaling')
@minValue(1)
@maxValue(12)
param partitionCount int = 1

@description('Optional: Resource ID of an existing Azure OpenAI service for shared private link')
param existingOpenAIResourceId string = ''

// Optional Private DNS zone + VNet link for Search
var linkName = 'link-search-${take(uniqueString(resourceGroup().id, name), 8)}'

module dns 'br/public:avm/res/network/private-dns-zone:0.7.0' = if (createDnsZone && empty(searchPrivateDnsZoneResourceId)) {
  name: 'dns-search-${uniqueString(resourceGroup().id, name)}'
  params: {
    name: searchDnsZoneName
    tags: tags
    virtualNetworkLinks: [
      {
        name: linkName
        virtualNetworkResourceId: dnsZoneVnetResourceId
        registrationEnabled: false
      }
    ]
  }
}

var effectiveSearchDnsZoneId = !empty(searchPrivateDnsZoneResourceId)
  ? searchPrivateDnsZoneResourceId
  : resourceId('Microsoft.Network/privateDnsZones', searchDnsZoneName)

// Azure AI Search (AVM)
module searchService 'br/public:avm/res/search/search-service:0.11.0' = {
  name: 'search-${uniqueString(resourceGroup().id, name)}'
  params: {
    name: name
    location: location
    sku: sku
    replicaCount: replicaCount
    partitionCount: partitionCount
    tags: tags

    managedIdentities: {
      systemAssigned: true
    }

    disableLocalAuth: true
    publicNetworkAccess: 'Disabled'

    networkRuleSet: {
      bypass: 'AzureServices'
      ipRules: []
    }

    privateEndpoints: [
      {
        name: '${toLower(name)}-pe'
        service: 'searchService'
        subnetResourceId: peSubnetId
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              name: 'search-dns'
              privateDnsZoneResourceId: effectiveSearchDnsZoneId
            }
          ]
        }
        tags: tags
      }
    ]

    semanticSearch: 'standard'

    sharedPrivateLinkResources: !empty(existingOpenAIResourceId) ? [
      {
        name: '${toLower(name)}-openai-spl'
        groupId: 'openai_account'
        privateLinkResourceId: existingOpenAIResourceId
        requestMessage: 'Shared private link for Azure AI Search to Azure OpenAI integration'
      }
    ] : []
  }
}

// Outputs
output name string = searchService.outputs.name
output resourceId string = searchService.outputs.resourceId
output endpoint string = searchService.outputs.endpoint
output systemAssignedMIPrincipalId string = searchService.outputs.systemAssignedMIPrincipalId!
@secure()
output primaryKey string = searchService.outputs.primaryKey
@secure()
output secondaryKey string = searchService.outputs.secondaryKey
