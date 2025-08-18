/**
  Module: Azure Functions Flex Consumption (FC1) app with essentials
  Encapsulates storage (AVM), plan (AVM), function app (native), VNet integration,
  RBAC, optional Private DNS zone + VNet link (local AVM-backed wrapper), and Private Endpoint (AVM).
*/

@description('Primary region for all resources')
param location string

@description('Globally unique Function App name (will become <appName>.azurewebsites.net)')
@minLength(2)
param appName string

@description('Language runtime used by the function app')
@allowed(['dotnet-isolated','python','java','node','powerShell'])
param functionAppRuntime string = 'python'

@description('Target language version used by the function app')
// Examples: dotnet-isolated:8.0, python:3.12, node:20, java:17, powerShell:7.4
param functionAppRuntimeVersion string = '3.12'

@description('Maximum scale-out instance count limit')
@minValue(40)
@maxValue(1000)
param maximumInstanceCount int = 100

@description('Memory size per instance (MB)')
@allowed([2048, 4096])
param instanceMemoryMB int = 2048

@description('Optional storage account name (must be globally unique, 3-24 lowercase letters/numbers). If empty, a name will be generated.')
param storageAccountName string = ''

@description('Optional deployment container name (3-63 lowercase). If empty, a name will be generated.')
param deploymentContainerName string = ''

@description('Resource tags')
param tags object = {}

@description('Resource ID of the subnet to use for Function App VNet Integration (outbound). Must be delegated to Microsoft.App/environments and not used for private endpoints.')
param vnetIntegrationSubnetResourceId string

@description('Resource ID of the subnet where the Private Endpoint for the Function App will be created (inbound private access).')
param privateEndpointSubnetResourceId string

@description('Optional resource ID of an existing Private DNS zone for privatelink.azurewebsites.net. If provided, a DNS zone group will be attached to the Private Endpoint.')
param privateDnsZoneWebsitesResourceId string = ''

@description('Optional Virtual Network resource ID to create and link an Azure Websites Private DNS zone (privatelink.azurewebsites.net). If provided and no zone ID is given, a new zone will be created and linked to this VNet.')
param websitesPrivateDnsVnetResourceId string = ''

// ----------------------------------------------------------------------------
// Required application settings for the ingest Function App
// These are passed in from the base template (some computed from deployed resources)
// ----------------------------------------------------------------------------
@description('Document Intelligence endpoint, e.g., https://<doc-intel-name>.cognitiveservices.azure.com/')
param docIntelEndpoint string = ''

@description('Azure OpenAI endpoint, e.g., https://<openai-name>.openai.azure.com/')
param azureOpenAIEndpoint string = ''

@description('Azure OpenAI chat deployment name')
param azureOpenAIDeploymentName string = ''

@description('Azure AI Search service endpoint, e.g., https://<search-name>.search.windows.net')
param azureSearchServiceEndpoint string = ''

@description('Azure AI Search target index name')
param azureSearchIndexName string = ''

// ----------------------------------------------------------------------------
// Name generation helpers
// ----------------------------------------------------------------------------
// Storage account name: derive from appName for readability + deterministic suffix for uniqueness
var appNamePrefix = toLower(take(replace(replace(replace(appName, '-', ''), '_', ''), '.', ''), 10))
var stgSuffix = toLower(take(uniqueString(subscription().id, resourceGroup().id, appName, 'func-stg'), 8))
var stgName = !empty(storageAccountName) ? toLower(storageAccountName) : 'st${appNamePrefix}${stgSuffix}'
var deployContainer = !empty(deploymentContainerName) ? toLower(deploymentContainerName) : 'funcpkg${toLower(take(uniqueString(appName), 8))}'
var planName = 'plan-${toLower(take(uniqueString(resourceGroup().id, appName), 8))}'
var dnsVnetLinkName = 'link-${toLower(take(uniqueString(resourceGroup().id, appName), 8))}'

// ----------------------------------------------------------------------------
// Storage (AVM module) with a private blob container for one-deploy package storage
// ----------------------------------------------------------------------------
module storage 'br/public:avm/res/storage/storage-account:0.26.0' = {
  name: 'stg-${uniqueString(resourceGroup().id, appName)}'
  params: {
    name: stgName
    location: location
    kind: 'StorageV2'
    skuName: 'Standard_LRS'
    minimumTlsVersion: 'TLS1_2'
    allowSharedKeyAccess: false
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
    blobServices: {
      containers: [
        {
          name: deployContainer
          publicAccess: 'None'
        }
      ]
    }
    tags: tags
  }
}

// ----------------------------------------------------------------------------
// App Service Plan (Flex Consumption) via AVM
// ----------------------------------------------------------------------------
module plan 'br/public:avm/res/web/serverfarm:0.5.0' = {
  name: 'plan-${uniqueString(resourceGroup().id, appName)}'
  params: {
    name: planName
    location: location
    kind: 'functionapp'
    skuName: 'FC1'
    reserved: true // Linux
    tags: tags
  }
}

// ----------------------------------------------------------------------------
// Private DNS Zone for Azure Websites + VNet link (optional helper)
// Create only when no zone ID is provided and a VNet ID is provided
// ----------------------------------------------------------------------------
module websitesPrivateDns './privateDnsWebsites.bicep' = {
  name: 'dns-websites-${uniqueString(resourceGroup().id, appName)}'
  params: {
    dnsZoneName: 'privatelink.azurewebsites.net'
    vnetResourceId: websitesPrivateDnsVnetResourceId
    vnetLinkName: dnsVnetLinkName
    tags: tags
  }
}

// Safe effective DNS zone resource ID to use for the PE
var effectiveWebsitesPrivateDnsZoneId = !empty(privateDnsZoneWebsitesResourceId)
  ? privateDnsZoneWebsitesResourceId
  : (!empty(websitesPrivateDnsVnetResourceId) ? websitesPrivateDns.outputs.dnsZoneResourceId : '')

// Existing resource handle for the storage account (for RBAC scope)
resource storageExisting 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: stgName
}

// ----------------------------------------------------------------------------
// Function App (Linux) with system-assigned identity and functionAppConfig
// ----------------------------------------------------------------------------
resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: appName
  location: location
  kind: 'functionapp,linux'
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    httpsOnly: true
    serverFarmId: plan.outputs.resourceId
    siteConfig: {
      minTlsVersion: '1.2'
      alwaysOn: false
    }
    functionAppConfig: {
      runtime: {
        name: functionAppRuntime
        version: functionAppRuntimeVersion
      }
      scaleAndConcurrency: {
        maximumInstanceCount: maximumInstanceCount
        instanceMemoryMB: instanceMemoryMB
      }
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.outputs.primaryBlobEndpoint}${deployContainer}'
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
    }
  }

  // App Settings (identity-based AzureWebJobsStorage)
  resource appSettings 'config' = {
    name: 'appsettings'
    properties: {
      AzureWebJobsStorage__credential: 'managedidentity'
      AzureWebJobsStorage__accountName: storage.outputs.name
  // Required app settings for the function runtime
  DOC_INTEL_ENDPOINT: docIntelEndpoint
  AZURE_OPENAI_ENDPOINT: azureOpenAIEndpoint
  AZURE_OPENAI_DEPLOYMENT_NAME: azureOpenAIDeploymentName
  AZURE_SEARCH_SERVICE_ENDPOINT: azureSearchServiceEndpoint
  AZURE_SEARCH_INDEX_NAME: azureSearchIndexName
    }
  }
}

// ----------------------------------------------------------------------------
// Function App VNet Integration (Outbound) - regional VNet integration
// ----------------------------------------------------------------------------
resource functionAppVnetIntegration 'Microsoft.Web/sites/networkConfig@2024-04-01' = {
  name: 'virtualNetwork'
  parent: functionApp
  properties: {
    subnetResourceId: vnetIntegrationSubnetResourceId
  }
}

// ----------------------------------------------------------------------------
// RBAC: grant the Function App identity Blob Data Contributor on the storage account
// ----------------------------------------------------------------------------
var roleIdBlobDataContributor = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

resource storageBlobDataContributorRA 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, resourceId('Microsoft.Storage/storageAccounts', stgName), functionApp.id, 'Storage Blob Data Contributor')
  scope: storageExisting
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIdBlobDataContributor)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ----------------------------------------------------------------------------
// Private Endpoint for the Function App (Inbound private access) via AVM
// ----------------------------------------------------------------------------
module peFunctionApp 'br/public:avm/res/network/private-endpoint:0.11.0' = {
  name: 'pe-${uniqueString(resourceGroup().id, appName)}'
  params: {
    name: 'pe-${toLower(appName)}'
    location: location
    subnetResourceId: privateEndpointSubnetResourceId
    privateLinkServiceConnections: [
      {
        name: 'pe-${toLower(appName)}-pls'
        properties: {
          privateLinkServiceId: functionApp.id
          groupIds: [ 'sites' ]
        }
      }
    ]
    privateDnsZoneGroup: !empty(effectiveWebsitesPrivateDnsZoneId) ? {
      name: 'default'
      privateDnsZoneGroupConfigs: [
        {
          name: 'websites'
          privateDnsZoneResourceId: effectiveWebsitesPrivateDnsZoneId
        }
      ]
    } : null
    tags: tags
  }
}

// ----------------------------------------------------------------------------
// Outputs
// ----------------------------------------------------------------------------
output functionAppName string = functionApp.name
output functionAppId string = functionApp.id
output functionAppDefaultHostname string = functionApp.properties.defaultHostName
output planId string = plan.outputs.resourceId
output storageAccountId string = storage.outputs.resourceId
output deploymentContainerUrl string = '${storage.outputs.primaryBlobEndpoint}${deployContainer}'
output functionAppPrincipalId string = functionApp.identity.principalId!
