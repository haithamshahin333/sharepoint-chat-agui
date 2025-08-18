/**
  Solution-wide Storage Account with Blob Private Endpoint (AVM)
  - Creates a StorageV2 account (private network only)
  - Creates a Blob container
  - Adds a Private Endpoint for blob with Private DNS zone group
  - System-assigned managed identity enabled

  Uses AVM storage-account module.
*/

targetScope = 'resourceGroup'

@description('Location for the storage account')
param location string = resourceGroup().location

@description('Name of the blob container to create')
param blobContainerName string

@description('Storage account SKU')
param storageAccountSku string = 'Standard_LRS'

@description('Resource ID of the subnet for the private endpoint')
param subnetResourceId string

@description('Resource ID of the private DNS zone for blob storage')
param privateDnsZoneResourceId string

@description('Tags to apply to resources')
param tags object = {}

// Generate unique storage account name based on RG + Subscription
var uniqueSuffix = take(uniqueString(resourceGroup().id, subscription().subscriptionId), 8)
var storageAccountName = 'st${toLower(take(replace(replace(resourceGroup().name, '-', ''), '_', ''), 12))}${uniqueSuffix}'

module privateStorageAccount 'br/public:avm/res/storage/storage-account:0.26.0' = {
  name: 'stg-${uniqueString(resourceGroup().id, storageAccountName)}'
  params: {
    name: storageAccountName
    location: location
    skuName: storageAccountSku
    kind: 'StorageV2'
    tags: tags

    // Security configurations
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    requireInfrastructureEncryption: true
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'

    // Network security - deny public access by default
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }

    // Managed identity
    managedIdentities: {
      systemAssigned: true
    }

    // Blob service and container configuration
    blobServices: {
      containerDeleteRetentionPolicyEnabled: true
      containerDeleteRetentionPolicyDays: 7
      deleteRetentionPolicyEnabled: true
      deleteRetentionPolicyDays: 6
      containers: [
        {
          name: blobContainerName
          publicAccess: 'None'
        }
      ]
    }

    // Note: Private endpoint created via dedicated module below to avoid reference() issues
  }
}

// Create Blob Private Endpoint using dedicated AVM module
module blobPrivateEndpoint 'br/public:avm/res/network/private-endpoint:0.11.0' = {
  name: 'pe-${uniqueString(resourceGroup().id, storageAccountName)}'
  params: {
    name: '${storageAccountName}-blob-pe'
    location: location
    subnetResourceId: subnetResourceId
    privateLinkServiceConnections: [
      {
        name: 'pls-blob'
        properties: {
          privateLinkServiceId: privateStorageAccount.outputs.resourceId
          groupIds: [ 'blob' ]
        }
      }
    ]
    privateDnsZoneGroup: {
      name: 'default'
      privateDnsZoneGroupConfigs: [
        {
          name: 'blob'
          privateDnsZoneResourceId: privateDnsZoneResourceId
        }
      ]
    }
    tags: tags
  }
}

// Outputs
@description('The name of the deployed storage account')
output storageAccountName string = privateStorageAccount.outputs.name

@description('The resource ID of the deployed storage account')
output storageAccountResourceId string = privateStorageAccount.outputs.resourceId

@description('The name of the blob container')
output containerName string = blobContainerName

@description('The blob service endpoint URL')
output blobServiceEndpoint string = privateStorageAccount.outputs.primaryBlobEndpoint

@description('The private endpoint details')
output privateEndpointDetails array = [
  {
    name: blobPrivateEndpoint.outputs.name
    id: blobPrivateEndpoint.outputs.resourceId
  }
]

@description('The system-assigned managed identity principal ID')
output systemAssignedIdentityPrincipalId string = privateStorageAccount.outputs.systemAssignedMIPrincipalId!

@description('The service endpoints of the storage account')
output serviceEndpoints object = privateStorageAccount.outputs.serviceEndpoints
