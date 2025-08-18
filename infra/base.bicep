/**
  Base deployment: everything except the Web Apps and their centralized Websites DNS.
  Keeps Function (Flex), Logic App (optional), VNet/subnets, Storage, Cosmos, Search,
  OpenAI Private Endpoint, Document Intelligence, shared blob/cognitive DNS, and RBAC.
*/

@description('Primary region for all resources')
param location string = resourceGroup().location

@description('Prefix used to generate a globally unique Function App name. Final name will be <prefix>-<stable-hash>.azurewebsites.net')
@minLength(2)
param appNamePrefix string = 'dev'

// Construct a stable app name based on the resource group and prefix (idempotent across re-runs in the same RG)
var appName = toLower('${appNamePrefix}-${uniqueString(resourceGroup().id, appNamePrefix, 'func')}')

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

@description('Optional: Resource ID of the subnet to use for Function App VNet Integration (outbound). For Flex Consumption, must be delegated to Microsoft.App/environments and not used for private endpoints. Leave empty if using deploySolutionVnet.')
param vnetIntegrationSubnetResourceId string = ''

@description('Optional: Resource ID of the subnet where the Private Endpoint for the Function App will be created (inbound private access). Leave empty if using deploySolutionVnet.')
param privateEndpointSubnetResourceId string = ''

@description('Optional resource ID of an existing Private DNS zone for privatelink.azurewebsites.net. If provided, a DNS zone group will be attached to the Private Endpoint.')
param privateDnsZoneWebsitesResourceId string = ''

@description('Optional Virtual Network resource ID to create and link an Azure Websites Private DNS zone (privatelink.azurewebsites.net). If provided and no zone ID is given, a new zone will be created and linked to this VNet.')
param websitesPrivateDnsVnetResourceId string = ''

@description('Optional shared Private DNS zone resource ID for privatelink.blob.* to reuse across modules')
param sharedBlobPrivateDnsZoneResourceId string = ''

@description('Set to true to create a shared Private DNS zone for privatelink.blob.* and link it to a VNet when no shared zone ID is provided')
param createSharedBlobDnsZone bool = false

@description('Virtual Network resource ID to link the shared blob Private DNS zone (required when createSharedBlobDnsZone = true and no zone ID provided)')
param sharedBlobDnsZoneVnetResourceId string = ''

// Shared blob Private DNS zone (privatelink.blob.<suffix>), created once and reused by modules
var storageSuffix = environment().suffixes.storage
var sharedBlobDnsZoneName = 'privatelink.blob.${storageSuffix}'

// Unique per-deployment suffix to avoid nested DeploymentActive conflicts
@description('Unique suffix for nested deployment names; defaults to a 6-char GUID fragment')
param deploymentInstance string = toLower(take(replace(newGuid(), '-', ''), 6))

// ------------------------------------------------------------
// Shared Cognitive Services Private DNS zone (privatelink.cognitiveservices.*)
// Centralized to avoid concurrent creation by multiple modules
// ------------------------------------------------------------

@description('Existing Private DNS zone resource ID for privatelink.cognitiveservices.* to reuse across Cognitive Services (OpenAI, Document Intelligence).')
param cognitiveServicesPrivateDnsZoneResourceId string = ''

@description('Set to true to create a shared Cognitive Services Private DNS zone and link it to a VNet when no zone ID is provided')
param createCognitiveServicesDnsZone bool = false

@description('Virtual Network resource ID to link the shared Cognitive Services Private DNS zone (required when createCognitiveServicesDnsZone = true and no zone ID provided)')
param cognitiveServicesDnsZoneVnetResourceId string = ''

// DNS zone name (parameterize later for sovereign clouds if needed)
var cognitiveServicesDnsZoneName = 'privatelink.cognitiveservices.azure.com'

@description('Whether to create a VNet link for the Cognitive Services Private DNS zone when creating the zone here. Set to false if the zone is already linked to your VNet to avoid conflicts.')
param linkCognitiveServicesDnsToVnet bool = true

// ------------------------------------------------------------
// Solution Virtual Network (optional) – provides integration and PE subnets
// ------------------------------------------------------------

@description('Set to true to deploy a solution VNet with integration and private endpoint subnets')
param deploySolutionVnet bool = false

@description('Optional: Solution VNet name (if empty, a stable name will be generated)')
param solutionVnetName string = ''

@description('Solution VNet address space CIDR (e.g., 10.0.0.0/16). Required when deploySolutionVnet = true')
param solutionVnetAddressSpace string = ''

@description('Flex Functions integration subnet name (used when deploySolutionVnet = true)')
param flexIntegrationSubnetName string = 'flex-integration'

@description('Flex Functions integration subnet CIDR (used when deploySolutionVnet = true)')
param flexIntegrationSubnetPrefix string = '10.0.0.0/24'

@description('App/Logic App integration subnet name (used when deploySolutionVnet = true)')
param appIntegrationSubnetName string = 'app-integration'

@description('App/Logic App integration subnet CIDR (used when deploySolutionVnet = true)')
param appIntegrationSubnetPrefix string = '10.0.1.0/24'

@description('Private Endpoints subnet name (used when deploySolutionVnet = true)')
param peSubnetName string = 'private-endpoints'

@description('Private Endpoints subnet CIDR (used when deploySolutionVnet = true)')
param peSubnetPrefix string = '10.0.2.0/24'

// Effective names with deterministic fallbacks
var effectiveSolutionVnetName = !empty(solutionVnetName) ? solutionVnetName : 'vnet-${uniqueString(resourceGroup().id, 'solution-vnet')}'

module vnet 'modules/solutionVnet.bicep' = if (deploySolutionVnet) {
  name: 'vnet-${uniqueString(resourceGroup().id, effectiveSolutionVnetName, deploymentInstance)}'
  params: {
    name: effectiveSolutionVnetName
    location: location
    addressSpace: solutionVnetAddressSpace
    flexIntegrationSubnetName: flexIntegrationSubnetName
    flexIntegrationSubnetPrefix: flexIntegrationSubnetPrefix
    appIntegrationSubnetName: appIntegrationSubnetName
    appIntegrationSubnetPrefix: appIntegrationSubnetPrefix
    peSubnetName: peSubnetName
    peSubnetPrefix: peSubnetPrefix
    tags: tags
  }
}

// Effective VNet/Subnet IDs (construct IDs deterministically; add explicit dependsOn in consuming modules for ordering)
var effectiveVnetId = deploySolutionVnet ? resourceId('Microsoft.Network/virtualNetworks', effectiveSolutionVnetName) : ''
var effectiveFlexIntegrationSubnetId = !empty(vnetIntegrationSubnetResourceId) ? vnetIntegrationSubnetResourceId : (deploySolutionVnet ? '${effectiveVnetId}/subnets/${flexIntegrationSubnetName}' : '')
var effectiveAppIntegrationSubnetId = deploySolutionVnet ? '${effectiveVnetId}/subnets/${appIntegrationSubnetName}' : ''
var effectivePeSubnetId = !empty(privateEndpointSubnetResourceId) ? privateEndpointSubnetResourceId : (deploySolutionVnet ? '${effectiveVnetId}/subnets/${peSubnetName}' : '')
var effectiveWebsitesPrivateDnsVnetResourceId = !empty(websitesPrivateDnsVnetResourceId) ? websitesPrivateDnsVnetResourceId : (deploySolutionVnet ? effectiveVnetId : '')
var effectiveSharedBlobDnsZoneVnetResourceId = !empty(sharedBlobDnsZoneVnetResourceId) ? sharedBlobDnsZoneVnetResourceId : (deploySolutionVnet ? effectiveVnetId : '')

// Effective DNS zone VNet IDs for Cosmos and Search (fallback to solution VNet if enabled)
@description('Virtual Network resource ID to link the Cosmos Private DNS zone (optional)')
param cosmosDnsZoneVnetResourceId string = ''
@description('Virtual Network resource ID to link the Search Private DNS zone (optional)')
param searchDnsZoneVnetResourceId string = ''
var effectiveCosmosDnsZoneVnetResourceId = !empty(cosmosDnsZoneVnetResourceId) ? cosmosDnsZoneVnetResourceId : effectiveVnetId
var effectiveSearchDnsZoneVnetResourceId = !empty(searchDnsZoneVnetResourceId) ? searchDnsZoneVnetResourceId : effectiveVnetId

// If Solution Storage is enabled but no blob DNS zone is provided anywhere, create the shared zone automatically and link to a VNet
var shouldCreateSharedBlobDnsZone = createSharedBlobDnsZone || (deploySolutionStorage && empty(solutionStorageBlobPrivateDnsZoneResourceId) && empty(sharedBlobPrivateDnsZoneResourceId))

module sharedBlobDns 'br/public:avm/res/network/private-dns-zone:0.7.0' = if (shouldCreateSharedBlobDnsZone && empty(sharedBlobPrivateDnsZoneResourceId)) {
  name: 'dns-shared-blob-${uniqueString(resourceGroup().id, deploymentInstance)}'
  dependsOn: deploySolutionVnet ? [ vnet ] : []
  params: {
    name: sharedBlobDnsZoneName
    tags: tags
    virtualNetworkLinks: [
      {
        name: 'link-${take(uniqueString(resourceGroup().id), 6)}'
        virtualNetworkResourceId: effectiveSharedBlobDnsZoneVnetResourceId
        registrationEnabled: false
      }
    ]
  }
}

var effectiveSharedBlobDnsZoneResourceId = !empty(sharedBlobPrivateDnsZoneResourceId)
  ? sharedBlobPrivateDnsZoneResourceId
  : (shouldCreateSharedBlobDnsZone ? resourceId('Microsoft.Network/privateDnsZones', sharedBlobDnsZoneName) : '')

// ------------------------------------------------------------
// Shared Cognitive Services DNS zone orchestration
// ------------------------------------------------------------

// Prefer explicit shared zone param; else reuse any module-specific inputs; else create if requested/needed
@description('Existing Cognitive Services Private DNS zone resource ID passed to individual modules (optional)')
param documentIntelligencePrivateDnsZoneResourceId string = ''
@description('Existing Cognitive Services Private DNS zone resource ID passed to OpenAI PE (optional)')
param openAIPrivateDnsZoneResourceId string = ''

var anyProvidedCognitiveZoneId = !empty(cognitiveServicesPrivateDnsZoneResourceId)
  ? cognitiveServicesPrivateDnsZoneResourceId
  : (!empty(documentIntelligencePrivateDnsZoneResourceId)
    ? documentIntelligencePrivateDnsZoneResourceId
    : (!empty(openAIPrivateDnsZoneResourceId) ? openAIPrivateDnsZoneResourceId : ''))

// Determine if we should create the shared Cognitive Services DNS zone
@description('Deploy OpenAI Private Endpoint toggle (affects DNS zone creation)')
param deployOpenAIPrivateEndpoint bool = false
@description('Deploy Document Intelligence toggle (affects DNS zone creation)')
param deployDocumentIntelligence bool = false

var shouldCreateCognitiveServicesDnsZone = createCognitiveServicesDnsZone || ((deployDocumentIntelligence || deployOpenAIPrivateEndpoint) && empty(anyProvidedCognitiveZoneId) && !empty(effectiveVnetId))

// Create the shared Cognitive Services DNS zone when needed (single source of truth)
module sharedCogSvcDns 'br/public:avm/res/network/private-dns-zone:0.7.0' = if (shouldCreateCognitiveServicesDnsZone && empty(anyProvidedCognitiveZoneId)) {
  name: 'dns-cogsvc-${uniqueString(resourceGroup().id, deploymentInstance)}'
  dependsOn: deploySolutionVnet ? [ vnet ] : []
  params: {
    name: cognitiveServicesDnsZoneName
    tags: tags
    virtualNetworkLinks: linkCognitiveServicesDnsToVnet ? [
      {
        name: 'link-${take(uniqueString(resourceGroup().id), 6)}'
        virtualNetworkResourceId: (!empty(cognitiveServicesDnsZoneVnetResourceId) ? cognitiveServicesDnsZoneVnetResourceId : effectiveVnetId)
        registrationEnabled: false
      }
    ] : []
  }
}

var effectiveCognitiveServicesDnsZoneResourceId = !empty(anyProvidedCognitiveZoneId)
  ? anyProvidedCognitiveZoneId
  : (shouldCreateCognitiveServicesDnsZone ? resourceId('Microsoft.Network/privateDnsZones', cognitiveServicesDnsZoneName) : '')

// NOTE: Cannot safely access conditional module outputs (docintel) at compile time without nullability warning.
// For now keep original construction using effectiveDocumentIntelligenceName; consider refactoring module to always deploy (with enable flag) to use outputs.endpoint.
var docIntelEndpointValue = deployDocumentIntelligence ? 'https://${effectiveDocumentIntelligenceName}.cognitiveservices.azure.com/' : ''

// ------------------------------------------------------------
// Flex Function App (core)
// ------------------------------------------------------------

// Required application settings for the function app
@description('Azure OpenAI chat deployment name to use in the function app')
param azureOpenAIDeploymentName string = ''

@description('Azure AI Search index name for the function app')
param azureSearchIndexName string = ''

module flex 'modules/flexFunctionApp.bicep' = {
  name: 'flex-${uniqueString(resourceGroup().id, appName, deploymentInstance)}'
  dependsOn: deploySolutionVnet ? [ vnet ] : []
  params: {
    location: location
    appName: appName
    functionAppRuntime: functionAppRuntime
    functionAppRuntimeVersion: functionAppRuntimeVersion
    maximumInstanceCount: maximumInstanceCount
    instanceMemoryMB: instanceMemoryMB
    storageAccountName: storageAccountName
    deploymentContainerName: deploymentContainerName
    tags: tags
    vnetIntegrationSubnetResourceId: effectiveFlexIntegrationSubnetId
    privateEndpointSubnetResourceId: effectivePeSubnetId
    privateDnsZoneWebsitesResourceId: privateDnsZoneWebsitesResourceId
    websitesPrivateDnsVnetResourceId: effectiveWebsitesPrivateDnsVnetResourceId
  // Wire required app settings
  // Pass the resolved (safe) Document Intelligence endpoint
  docIntelEndpoint: docIntelEndpointValue
  azureOpenAIEndpoint: (!empty(openAIResourceId) ? 'https://${oaiName}.openai.azure.com/' : '')
  azureOpenAIDeploymentName: azureOpenAIDeploymentName
  azureSearchServiceEndpoint: (deploySearch ? 'https://${effectiveSearchServiceName}.search.windows.net' : '')
  azureSearchIndexName: azureSearchIndexName
  }
}

output functionAppName string = flex.outputs.functionAppName
output functionAppId string = flex.outputs.functionAppId
output functionAppDefaultHostname string = flex.outputs.functionAppDefaultHostname
output planId string = flex.outputs.planId
output storageAccountId string = flex.outputs.storageAccountId
output deploymentContainerUrl string = flex.outputs.deploymentContainerUrl

// ------------------------------------------------------------
// Logic App Standard (optional)
// ------------------------------------------------------------

@description('Set to true to deploy the Logic App Standard module')
param deployLogicApp bool = false

@description('Optional: Logic App Standard name (if empty, a stable name will be generated)')
param logicAppName string = ''

@description('Subnet resource ID for Logic App VNet Integration (required when deployLogicApp = true)')
param logicAppIntegrationSubnetResourceId string = ''

@description('Virtual Network resource ID to link Private DNS zones for Storage (required when deployLogicApp = true)')
param logicAppVnetResourceId string = ''

@description('Subnet resource ID where Storage Private Endpoints (blob/file) will be created (required when deployLogicApp = true)')
param logicAppStoragePrivateEndpointSubnetResourceId string = ''

@description('Optional storage account name for the Logic App (leave empty to auto-generate)')
param logicAppStorageAccountName string = ''

@description('Optional Azure Files share name for Logic App content (default: lasruntime)')
param logicAppFileShareName string = 'lasruntime'

@description('Optional Application Insights connection string for Logic App')
param logicAppApplicationInsightsConnectionString string = ''

@description('Optional additional app settings for Logic App as an object map')
param logicAppAdditionalAppSettings object = {}

var effectiveLogicAppName = !empty(logicAppName) ? logicAppName : 'las-${uniqueString(resourceGroup().id, 'logicapp')}'

module logicApp 'modules/logicappStandard.bicep' = {
  name: 'la-${uniqueString(resourceGroup().id, effectiveLogicAppName, deploymentInstance)}'
  dependsOn: deploySolutionVnet ? [ vnet ] : []
  params: {
    name: effectiveLogicAppName
    location: location
    tags: tags
    integrationSubnetId: (!empty(logicAppIntegrationSubnetResourceId) ? logicAppIntegrationSubnetResourceId : effectiveAppIntegrationSubnetId)
    vnetResourceId: (!empty(logicAppVnetResourceId) ? logicAppVnetResourceId : effectiveVnetId)
    storagePrivateEndpointSubnetResourceId: (!empty(logicAppStoragePrivateEndpointSubnetResourceId) ? logicAppStoragePrivateEndpointSubnetResourceId : effectivePeSubnetId)
    blobPrivateDnsZoneResourceId: effectiveSharedBlobDnsZoneResourceId
  // Skip blob DNS VNet link in module when base created & linked shared zone this deployment
  skipBlobDnsLink: (shouldCreateSharedBlobDnsZone && empty(sharedBlobPrivateDnsZoneResourceId))
    storageAccountName: logicAppStorageAccountName
    fileShareName: logicAppFileShareName
    applicationInsightsConnectionString: logicAppApplicationInsightsConnectionString
  additionalAppSettings: logicAppAdditionalAppSettings
  }
}

// ------------------------------------------------------------
// SharePoint Online Connection (optional; manual OAuth required post-deploy)
// ------------------------------------------------------------
@description('Set to true to deploy the SharePoint Online API connection (manual user authorization will still be required).')
param deploySharePointConnection bool = false
@description('Optional: SharePoint connection resource name (default sharepointonline).')
param sharePointConnectionName string = ''
@description('Display name for the SharePoint connection before authorization.')
param sharePointConnectionDisplayName string = 'SharePoint (manual auth pending)'
var effectiveSharePointConnectionName = !empty(sharePointConnectionName) ? sharePointConnectionName : 'sharepointonline'
module spoConn 'modules/sharePointConnection.bicep' = if (deploySharePointConnection && deployLogicApp) {
  name: 'spo-${uniqueString(resourceGroup().id, effectiveSharePointConnectionName, deploymentInstance)}'
  params: {
    location: location
    name: effectiveSharePointConnectionName
    displayName: sharePointConnectionDisplayName
    tags: tags
  logicAppPrincipalObjectId: deployLogicApp ? logicApp.outputs.principalId : ''
  }
}

// ------------------------------------------------------------
// Cosmos DB (optional)
// ------------------------------------------------------------

@description('Set to true to deploy Cosmos DB (serverless) with a private endpoint')
param deployCosmos bool = false

@description('Optional: Cosmos DB account name (if empty, a stable name will be generated)')
param cosmosAccountName string = ''

@description('Subnet resource ID for the Cosmos private endpoint (required when deployCosmos = true)')
param cosmosPrivateEndpointSubnetResourceId string = ''

@description('Existing Cosmos private DNS zone resource ID (privatelink.documents.*). Leave empty to auto-create when createCosmosDnsZone = true')
param cosmosPrivateDnsZoneResourceId string = ''

@description('Set to true to create the Cosmos Private DNS zone and link to a VNet when no zone ID provided')
param createCosmosDnsZone bool = false

@description('Cosmos initial database and container names')
param cosmosDatabaseName string = 'MainDatabase'
param cosmosContainerName string = 'Documents'
param cosmosPartitionKeyPath string = '/id'

var effectiveCosmosAccountName = !empty(cosmosAccountName) ? cosmosAccountName : 'cos${uniqueString(resourceGroup().id, 'cosmos')}'

module cosmos 'modules/cosmosServerless.bicep' = if (deployCosmos) {
  name: 'cos-${uniqueString(resourceGroup().id, effectiveCosmosAccountName, deploymentInstance)}'
  dependsOn: deploySolutionVnet ? [ vnet ] : []
  params: {
    name: effectiveCosmosAccountName
    location: location
    tags: tags
    peSubnetId: (!empty(cosmosPrivateEndpointSubnetResourceId) ? cosmosPrivateEndpointSubnetResourceId : effectivePeSubnetId)
    cosmosPrivateDnsZoneResourceId: cosmosPrivateDnsZoneResourceId
    createDnsZone: createCosmosDnsZone
    cosmosDnsZoneVnetResourceId: effectiveCosmosDnsZoneVnetResourceId
    databaseName: cosmosDatabaseName
    containerName: cosmosContainerName
    partitionKeyPath: cosmosPartitionKeyPath
  }
}

// ------------------------------------------------------------
// Azure AI Search (optional)
// ------------------------------------------------------------

@description('Set to true to deploy Azure AI Search with Private Endpoint')
param deploySearch bool = false

@description('Optional: Azure AI Search service name (if empty, a stable name will be generated)')
param searchServiceName string = ''

@description('Subnet resource ID for the Search private endpoint (required when deploySearch = true)')
param searchPrivateEndpointSubnetResourceId string = ''

@description('Existing Search Private DNS zone resource ID (privatelink.search.*). Leave empty to auto-create when createSearchDnsZone = true')
param searchPrivateDnsZoneResourceId string = ''

@description('Set to true to create the Search Private DNS zone and link to a VNet when no zone ID provided')
param createSearchDnsZone bool = false

@description('Search SKU and scale')
@allowed([ 'basic', 'standard', 'standard2', 'standard3' ])
param searchSku string = 'standard'
@minValue(1)
@maxValue(12)
param searchReplicaCount int = 1
@minValue(1)
@maxValue(12)
param searchPartitionCount int = 1

@description('Optional: Resource ID of an existing Azure OpenAI (Cognitive Services) resource used for Search Shared Private Link, Private Endpoint, and RBAC')
param openAIResourceId string = ''

var effectiveSearchServiceName = !empty(searchServiceName) ? searchServiceName : 'search${uniqueString(resourceGroup().id, 'search')}'

module search 'modules/searchService.bicep' = if (deploySearch) {
  name: 'srch-${uniqueString(resourceGroup().id, effectiveSearchServiceName, deploymentInstance)}'
  dependsOn: deploySolutionVnet ? [ vnet ] : []
  params: {
    name: effectiveSearchServiceName
    location: location
    tags: tags
    peSubnetId: (!empty(searchPrivateEndpointSubnetResourceId) ? searchPrivateEndpointSubnetResourceId : effectivePeSubnetId)
    searchPrivateDnsZoneResourceId: searchPrivateDnsZoneResourceId
    createDnsZone: createSearchDnsZone
    dnsZoneVnetResourceId: effectiveSearchDnsZoneVnetResourceId
    sku: searchSku
    replicaCount: searchReplicaCount
    partitionCount: searchPartitionCount
  existingOpenAIResourceId: openAIResourceId
  }
}

// ------------------------------------------------------------
// Azure OpenAI Private Endpoint (optional)
// ------------------------------------------------------------

// (openAIResourceId param declared earlier)

@description('Name of the Private Endpoint to create (required when deployOpenAIPrivateEndpoint = true)')
param openAIPrivateEndpointName string = ''

@description('Subnet resource ID where the OpenAI Private Endpoint will be created (required when deployOpenAIPrivateEndpoint = true)')
param openAIPrivateEndpointSubnetResourceId string = ''

module openaiPe 'modules/openAIPrivateEndpoint.bicep' = if (deployOpenAIPrivateEndpoint) {
  name: 'oaipe-${uniqueString(resourceGroup().id, openAIPrivateEndpointName, deploymentInstance)}'
  dependsOn: [
    ...(deploySolutionVnet ? [ vnet ] : [])
    ...((shouldCreateCognitiveServicesDnsZone && empty(anyProvidedCognitiveZoneId)) ? [ sharedCogSvcDns ] : [])
  ]
  params: {
  existingOpenAIResourceId: openAIResourceId
    privateEndpointName: openAIPrivateEndpointName
    subnetResourceId: (!empty(openAIPrivateEndpointSubnetResourceId) ? openAIPrivateEndpointSubnetResourceId : effectivePeSubnetId)
    privateDnsZoneId: (!empty(openAIPrivateDnsZoneResourceId) ? openAIPrivateDnsZoneResourceId : effectiveCognitiveServicesDnsZoneResourceId)
    createDnsZone: false
    dnsZoneVnetResourceId: ''
    location: location
    tags: tags
  }
}

// ------------------------------------------------------------
// Azure Document Intelligence (Form Recognizer) with Private Endpoint (optional)
// ------------------------------------------------------------

@description('Optional: Document Intelligence account name (if empty, a stable name will be generated)')
param documentIntelligenceName string = ''

@description('Subnet resource ID for the Document Intelligence private endpoint (required when deployDocumentIntelligence = true)')
param documentIntelligencePrivateEndpointSubnetResourceId string = ''

var effectiveDocumentIntelligenceName = !empty(documentIntelligenceName) ? documentIntelligenceName : 'di${uniqueString(resourceGroup().id, 'docintel')}'

module docintel 'modules/documentIntelligence.bicep' = if (deployDocumentIntelligence) {
  name: 'docintel-${uniqueString(resourceGroup().id, effectiveDocumentIntelligenceName, deploymentInstance)}'
  dependsOn: [
    ...(deploySolutionVnet ? [ vnet ] : [])
    ...((shouldCreateCognitiveServicesDnsZone && empty(anyProvidedCognitiveZoneId)) ? [ sharedCogSvcDns ] : [])
  ]
  params: {
    name: effectiveDocumentIntelligenceName
    location: location
    peSubnetId: (!empty(documentIntelligencePrivateEndpointSubnetResourceId) ? documentIntelligencePrivateEndpointSubnetResourceId : effectivePeSubnetId)
    cognitiveServicesPrivateDnsZoneId: (!empty(documentIntelligencePrivateDnsZoneResourceId) ? documentIntelligencePrivateDnsZoneResourceId : effectiveCognitiveServicesDnsZoneResourceId)
    createDnsZone: false
    dnsZoneVnetResourceId: ''
    tags: tags
  }
}

// Grant Function App managed identity permission to invoke Document Intelligence (least privilege)
// Cognitive Services User role ID: a97b65f3-24c7-4388-baec-2e87135dc908 (allows key read & inference)
// Create an existing resource reference for the cognitive account to use as scope
resource docIntelAccount 'Microsoft.CognitiveServices/accounts@2023-05-01' existing = if (deployDocumentIntelligence) {
  name: effectiveDocumentIntelligenceName
}

resource docIntelCognitiveUserRA 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployDocumentIntelligence) {
  name: guid(subscription().id, docIntelAccount.id, flex.name, 'CognitiveServicesUser')
  scope: docIntelAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'a97b65f3-24c7-4388-baec-2e87135dc908')
    principalId: flex.outputs.functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ------------------------------------------------------------
// Solution-wide Storage Account (optional)
// ------------------------------------------------------------

@description('Set to true to deploy a solution-wide Storage Account with a blob Private Endpoint')
param deploySolutionStorage bool = false

@description('Blob container name to create in the solution storage (required when deploySolutionStorage = true)')
param solutionStorageBlobContainerName string = 'shared'

@description('Subnet resource ID for the Storage blob Private Endpoint (required when deploySolutionStorage = true)')
param solutionStoragePrivateEndpointSubnetResourceId string = ''

@description('Existing Private DNS zone resource ID for privatelink.blob.* (required)')
param solutionStorageBlobPrivateDnsZoneResourceId string = ''

@description('Storage SKU (default Standard_LRS)')
param solutionStorageSku string = 'Standard_LRS'

module solutionStorage 'modules/solutionStorage.bicep' = if (deploySolutionStorage) {
  name: 'solstg-${uniqueString(resourceGroup().id, solutionStorageBlobContainerName, deploymentInstance)}'
  dependsOn: [
    ...(deploySolutionVnet ? [ vnet ] : [])
    ...((shouldCreateSharedBlobDnsZone && empty(sharedBlobPrivateDnsZoneResourceId)) ? [ sharedBlobDns ] : [])
  ]
  params: {
    location: location
    tags: tags
    blobContainerName: solutionStorageBlobContainerName
    storageAccountSku: solutionStorageSku
    subnetResourceId: (!empty(solutionStoragePrivateEndpointSubnetResourceId) ? solutionStoragePrivateEndpointSubnetResourceId : effectivePeSubnetId)
    privateDnsZoneResourceId: !empty(solutionStorageBlobPrivateDnsZoneResourceId) ? solutionStorageBlobPrivateDnsZoneResourceId : effectiveSharedBlobDnsZoneResourceId
  }
}

// ------------------------------------------------------------
// RBAC
// ------------------------------------------------------------
var roleIdBlobDataContributor = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

// Deterministic Solution Storage account name (must match module derivation logic)
var solStgName = 'st${toLower(take(replace(replace(resourceGroup().name, '-', ''), '_', ''), 12))}${take(uniqueString(resourceGroup().id, subscription().subscriptionId), 8)}'

// Function App -> Solution Storage
module ra_func_solstg 'modules/assignRoleToStorage.bicep' = if (deploySolutionStorage) {
  name: 'ra-solstg-func-${uniqueString(resourceGroup().id, appName, deploymentInstance)}'
  dependsOn: [ solutionStorage ]
  params: {
    storageAccountName: solStgName
    principalId: flex.outputs.functionAppPrincipalId
    roleDefinitionId: roleIdBlobDataContributor
  }
}

// Logic App -> Solution Storage
module ra_las_solstg 'modules/assignRoleToStorage.bicep' = if (deploySolutionStorage && deployLogicApp) {
  name: 'ra-solstg-las-${uniqueString(resourceGroup().id, effectiveLogicAppName, deploymentInstance)}'
  dependsOn: [ solutionStorage ]
  params: {
    storageAccountName: solStgName
    principalId: deployLogicApp ? logicApp.outputs.principalId : ''
    roleDefinitionId: roleIdBlobDataContributor
  }
}

// Logic App -> Solution Storage

// RBAC: grant app identities access to Azure AI Search
var roleIdSearchIndexDataContributor = '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
var roleIdSearchServiceContributor = '7ca78c08-252a-4471-8644-bb5ff32d4ba0'

module ra_func_search_idx 'modules/assignRoleToSearch.bicep' = if (deploySearch) {
  name: 'ra-srch-idx-func-${uniqueString(resourceGroup().id, appName, deploymentInstance)}'
  params: {
    searchServiceName: effectiveSearchServiceName
    principalId: flex.outputs.functionAppPrincipalId
    roleDefinitionId: roleIdSearchIndexDataContributor
  }
}

module ra_func_search_svc 'modules/assignRoleToSearch.bicep' = if (deploySearch) {
  name: 'ra-srch-svc-func-${uniqueString(resourceGroup().id, appName, deploymentInstance)}'
  params: {
    searchServiceName: effectiveSearchServiceName
    principalId: flex.outputs.functionAppPrincipalId
    roleDefinitionId: roleIdSearchServiceContributor
  }
}

module ra_las_search_idx 'modules/assignRoleToSearch.bicep' = if (deploySearch && deployLogicApp) {
  name: 'ra-srch-idx-las-${uniqueString(resourceGroup().id, effectiveLogicAppName, deploymentInstance)}'
  params: {
    searchServiceName: effectiveSearchServiceName
  principalId: deployLogicApp ? logicApp.outputs.principalId : ''
    roleDefinitionId: roleIdSearchIndexDataContributor
  }
}

module ra_las_search_svc 'modules/assignRoleToSearch.bicep' = if (deploySearch && deployLogicApp) {
  name: 'ra-srch-svc-las-${uniqueString(resourceGroup().id, effectiveLogicAppName, deploymentInstance)}'
  params: {
    searchServiceName: effectiveSearchServiceName
  principalId: deployLogicApp ? logicApp.outputs.principalId : ''
    roleDefinitionId: roleIdSearchServiceContributor
  }
}


// RBAC: grant app identities access to Azure OpenAI (Cognitive Services)
var roleIdOpenAIUser = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'

var oaiSubId = !empty(openAIResourceId) ? split(openAIResourceId, '/')[2] : ''
var oaiRg = !empty(openAIResourceId) ? split(openAIResourceId, '/')[4] : ''
var oaiName = !empty(openAIResourceId) ? split(openAIResourceId, '/')[8] : ''

module oaiRoleFunc 'modules/assignRoleToOpenAI.bicep' = if (!empty(openAIResourceId)) {
  name: 'oai-ra-func-${uniqueString(resourceGroup().id, appName, deploymentInstance)}'
  scope: resourceGroup(oaiSubId, oaiRg)
  params: {
    accountName: oaiName
    principalId: flex.outputs.functionAppPrincipalId
    roleDefinitionId: roleIdOpenAIUser
  }
}

module oaiRoleLas 'modules/assignRoleToOpenAI.bicep' = if (!empty(openAIResourceId) && deployLogicApp) {
  name: 'oai-ra-las-${uniqueString(resourceGroup().id, effectiveLogicAppName, deploymentInstance)}'
  scope: resourceGroup(oaiSubId, oaiRg)
  params: {
    accountName: oaiName
  principalId: deployLogicApp ? logicApp.outputs.principalId : ''
    roleDefinitionId: roleIdOpenAIUser
  }
}
// Intermediate variable to avoid accessing module outputs when module not instantiated
// SharePoint connection output intentionally omitted to avoid conditional module dereference issues.

