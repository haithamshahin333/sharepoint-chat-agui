/**
  Cosmos DB (NoSQL) serverless with Private Endpoint and Private DNS (AVM)
  - Disables public network access
  - Creates PE for group 'Sql' into provided subnet
  - Attaches DNS zone group to privatelink.documents.* zone
  - Optionally creates the Private DNS zone and links it to a VNet

  Sources:
  - Cosmos DB serverless: https://learn.microsoft.com/azure/cosmos-db/serverless
  - Private endpoints (Cosmos + DNS): https://learn.microsoft.com/azure/cosmos-db/how-to-configure-private-endpoints
  - AVM index: https://azure.github.io/Azure-Verified-Modules/indexes/bicep/bicep-resource-modules/
*/

targetScope = 'resourceGroup'

@description('Cosmos DB account name')
param name string

@description('Azure location')
param location string = resourceGroup().location

@description('Subnet resource ID for the Private Endpoint')
param peSubnetId string

@description('Existing Cosmos DB Private DNS zone resource ID (privatelink.documents.*). Leave empty to create one if createDnsZone = true')
param cosmosPrivateDnsZoneResourceId string = ''

@description('Set to true to create a Private DNS zone for Cosmos and link it to a VNet when no zone ID is provided')
param createDnsZone bool = false

@description('Private DNS zone name for Cosmos (default public cloud)')
param cosmosDnsZoneName string = 'privatelink.documents.azure.com'

@description('VNet resource ID to link the Private DNS zone (required when createDnsZone = true and no zone ID provided)')
param cosmosDnsZoneVnetResourceId string = ''

@description('Tags to apply')
param tags object = {}

@description('Name of the initial SQL (NoSQL) database to create')
param databaseName string = 'MainDatabase'

@description('Name of the initial container to create')
param containerName string = 'Documents'

@description('Partition key path for the initial container')
param partitionKeyPath string = '/id'

// Optionally create Private DNS zone and VNet link using AVM
var linkName = 'link-docs-${take(uniqueString(resourceGroup().id, name), 8)}'

module dns 'br/public:avm/res/network/private-dns-zone:0.7.0' = if (createDnsZone && empty(cosmosPrivateDnsZoneResourceId)) {
  name: 'dns-cosmos-${uniqueString(resourceGroup().id, name)}'
  params: {
    name: cosmosDnsZoneName
    tags: tags
    virtualNetworkLinks: [
      {
        name: linkName
        virtualNetworkResourceId: cosmosDnsZoneVnetResourceId
        registrationEnabled: false
      }
    ]
  }
}

// Use existing zone ID if provided, else the one we created
var effectiveCosmosDnsZoneId = !empty(cosmosPrivateDnsZoneResourceId)
  ? cosmosPrivateDnsZoneResourceId
  : resourceId('Microsoft.Network/privateDnsZones', cosmosDnsZoneName)

// Cosmos DB account (AVM)
module cosmosAccount 'br/public:avm/res/document-db/database-account:0.15.0' = {
  name: 'cosmos-${uniqueString(resourceGroup().id, name)}'
  params: {
    name: name
    location: location
    tags: tags

    // Serverless configuration
    capabilitiesToAdd: [ 'EnableServerless' ]

    // Security: private networking only
    networkRestrictions: {
      publicNetworkAccess: 'Disabled'
      ipRules: []
      virtualNetworkRules: []
    }

    // Private Endpoint with DNS zone group
    privateEndpoints: [
      {
        name: '${toLower(name)}-pe'
        service: 'Sql'
        subnetResourceId: peSubnetId
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              name: 'cosmos-dns'
              privateDnsZoneResourceId: effectiveCosmosDnsZoneId
            }
          ]
        }
        tags: tags
      }
    ]

    // Consistency and availability suitable for serverless
    defaultConsistencyLevel: 'Session'
    automaticFailover: false
    enableMultipleWriteLocations: false
    zoneRedundant: false

    // Auth and backup
    disableLocalAuthentication: false
    backupPolicyType: 'Continuous'
    backupPolicyContinuousTier: 'Continuous30Days'

    // Create an initial database + container
    sqlDatabases: [
      {
        name: databaseName
        containers: [
          {
            name: containerName
            paths: [ partitionKeyPath ]
            indexingPolicy: {
              indexingMode: 'Consistent'
              automatic: true
              includedPaths: [
                {
                  path: '/*'
                }
              ]
              excludedPaths: [
                {
                  path: '/"_etag"/?'
                }
              ]
            }
          }
        ]
      }
    ]
  }
}

// Outputs
output name string = cosmosAccount.outputs.name
output resourceId string = cosmosAccount.outputs.resourceId
output endpoint string = cosmosAccount.outputs.endpoint
@secure()
output primaryReadWriteKey string = cosmosAccount.outputs.primaryReadWriteKey
@secure()
output primaryReadOnlyKey string = cosmosAccount.outputs.primaryReadOnlyKey
@secure()
output primaryReadWriteConnectionString string = cosmosAccount.outputs.primaryReadWriteConnectionString
@secure()
output primaryReadOnlyConnectionString string = cosmosAccount.outputs.primaryReadOnlyConnectionString
