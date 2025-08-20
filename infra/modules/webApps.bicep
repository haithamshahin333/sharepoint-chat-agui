/**
  Module: Two Linux Web Apps (Python + Next.js) on a shared App Service Plan with VNet integration and Private Endpoints
  - Creates a shared Linux App Service Plan (PremiumV3)
  - Creates two Web Apps (SystemAssigned identity), disables public network access, joins Regional VNet Integration
  - Creates Private Endpoints for each app with groupIds [sites, scm]
  - Attaches Private DNS zone group entries for privatelink.azurewebsites.net and privatelink.scm.azurewebsites.net when provided
*/

targetScope = 'resourceGroup'

@description('Location for all resources')
param location string = resourceGroup().location

@description('Tags to apply to all resources')
param tags object = {}

@description('App Service Plan name')
param planName string

@description('App Service Plan SKU name (e.g., P1v3)')
param planSku string = 'P1v3'

@description('Python Web App name')
param webPythonAppName string

@description('Next.js Web App name')
param webNextAppName string

@description('Node LTS version for Next.js (e.g., 22-lts)')
param nodeLts string = '22-lts'

@description('Resource ID of the integration subnet for Regional VNet Integration (must be delegated to Microsoft.Web/serverFarms)')
param appIntegrationSubnetId string

@description('Resource ID of the subnet for Private Endpoints')
param peSubnetId string

@description('Private DNS zone resource ID for privatelink.azurewebsites.net (optional)')
param websitesDnsZoneResourceId string = ''

@description('Private DNS zone resource ID for privatelink.scm.azurewebsites.net (optional)')
param websitesScmDnsZoneResourceId string = ''

// Optional resource IDs to grant the Python web app (backend) access via its managed identity
@description('Resource ID of the target Storage Account to assign Storage Blob Data Reader (optional)')
param storageAccountResourceId string = ''

@description('Resource ID of the Azure AI Search service to assign Search Index Data Reader (optional)')
param searchServiceResourceId string = ''

@description('Resource ID of the Azure OpenAI (Cognitive Services) account to assign Cognitive Services OpenAI User (optional)')
param openAiAccountResourceId string = ''

// Optional toggles to skip creating role assignments (useful when assignments already exist)
@description('Create Storage Blob Data Reader assignment for backend web app (default true)')
param createStorageRoleAssignment bool = true
@description('Create Search Index Data Reader assignment for backend web app (default true)')
param createSearchRoleAssignment bool = true
@description('Create Cognitive Services OpenAI User assignment for backend web app (default true)')
param createOpenAiRoleAssignment bool = true

// Shared Linux App Service Plan (PremiumV3)
resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: planName
  location: location
  sku: {
    name: planSku
    tier: 'PremiumV3'
  }
  properties: {
    reserved: true // Linux
    zoneRedundant: false
  }
  tags: tags
}

// Python Web App (Linux)
resource webPy 'Microsoft.Web/sites@2024-04-01' = {
  name: webPythonAppName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    publicNetworkAccess: 'Disabled'
    virtualNetworkSubnetId: appIntegrationSubnetId
    siteConfig: {
      linuxFxVersion: 'PYTHON|3.12'
      http20Enabled: true
      minTlsVersion: '1.2'
    }
  }
  tags: tags
}

// Built-in role definition IDs (static across clouds per docs)
// Storage Blob Data Reader
var roleIdStorageBlobDataReader = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
// Search Index Data Reader
var roleIdSearchIndexDataReader = '1407120a-92aa-4202-b7e9-c0e197c71c8f'
// Cognitive Services OpenAI User
var roleIdOpenAIUser = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'

// Parse resource IDs to extract subscriptionId, resourceGroup, and name
var stgParts = split(storageAccountResourceId, '/')
var stgName = length(stgParts) > 8 ? stgParts[8] : ''

var seaParts = split(searchServiceResourceId, '/')
var seaName = length(seaParts) > 8 ? seaParts[8] : ''

// OpenAI ID hardened parsing (avoid silent fallback to current RG)
// Expected full ID pattern segments (index: value):
// 1: subscriptions, 3: resourceGroups, 5: providers, 6: Microsoft.CognitiveServices, 7: accounts
var oaiParts = split(openAiAccountResourceId, '/')
var oaiValid = !empty(openAiAccountResourceId) && length(oaiParts) > 8 && toLower(oaiParts[1]) == 'subscriptions' && toLower(oaiParts[3]) == 'resourcegroups' && toLower(oaiParts[5]) == 'providers' && toLower(oaiParts[6]) == 'microsoft.cognitiveservices' && toLower(oaiParts[7]) == 'accounts' && !empty(oaiParts[8])
var oaiSubId = oaiValid ? oaiParts[2] : ''
var oaiRg = oaiValid ? oaiParts[4] : ''
var oaiName = oaiValid ? oaiParts[8] : ''

// Helper to get RG scope for a resource ID; when empty or same-RG, falls back to current RG (storage/search)
var stgScope = (!empty(storageAccountResourceId) && length(stgParts) > 4) ? resourceGroup(stgParts[2], stgParts[4]) : resourceGroup()
var seaScope = (!empty(searchServiceResourceId) && length(seaParts) > 4) ? resourceGroup(seaParts[2], seaParts[4]) : resourceGroup()
// For OpenAI we always produce a resourceGroup object (type requirement), but gate assignment on oaiValid so fallback scope is never used to attempt cross-RG assignment incorrectly.
var oaiScope = resourceGroup(oaiValid ? oaiSubId : subscription().subscriptionId, oaiValid ? oaiRg : resourceGroup().name)

// Assign Storage Blob Data Reader at the storage account resource scope via cross-RG module
module raStorageBlobReader 'rbac/assignRole.storage.bicep' = if (!empty(storageAccountResourceId) && createStorageRoleAssignment) {
  name: 'ra-stg-${uniqueString(stgParts[2], stgParts[4], stgName, webPy.name)}'
  scope: stgScope
  params: {
    storageAccountName: stgName
    principalId: webPy.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIdStorageBlobDataReader)
  }
}

// Assign Search Index Data Reader via cross-RG module
module raSearchReader 'rbac/assignRole.search.bicep' = if (!empty(searchServiceResourceId) && createSearchRoleAssignment) {
  name: 'ra-sea-${uniqueString(seaParts[2], seaParts[4], seaName, webPy.name)}'
  scope: seaScope
  params: {
    searchServiceName: seaName
    principalId: webPy.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIdSearchIndexDataReader)
  }
}

// Assign OpenAI User via cross-RG module
module raOpenAIUser 'rbac/assignRole.openai.bicep' = if (oaiValid && createOpenAiRoleAssignment) {
  name: 'ra-oai-${uniqueString(oaiSubId, oaiRg, oaiName, webPy.name)}'
  scope: oaiScope
  params: {
    openAiAccountName: oaiName
    principalId: webPy.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIdOpenAIUser)
  }
}

// Next.js Web App (Linux)
resource webNext 'Microsoft.Web/sites@2024-04-01' = {
  name: webNextAppName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    publicNetworkAccess: 'Disabled'
    virtualNetworkSubnetId: appIntegrationSubnetId
    siteConfig: {
      linuxFxVersion: 'NODE|${nodeLts}'
      http20Enabled: true
      minTlsVersion: '1.2'
      webSocketsEnabled: true
    }
  }
  tags: tags
}

// Build DNS Zone Group configs (conditionally include web/scm)
// If only the main websites zone is provided, reuse it for scm records (single-zone pattern)
// but avoid adding the same zone twice in the zone group to prevent DuplicatePrivateDnsZoneIds.
var effectiveScmDnsZoneResourceId = !empty(websitesScmDnsZoneResourceId) ? websitesScmDnsZoneResourceId : websitesDnsZoneResourceId
var includeDistinctScmZone = !empty(effectiveScmDnsZoneResourceId) && toLower(effectiveScmDnsZoneResourceId) != toLower(websitesDnsZoneResourceId)
var websitesDnsGroupConfigs = concat(
  !empty(websitesDnsZoneResourceId) ? [ { name: 'web', privateDnsZoneResourceId: websitesDnsZoneResourceId } ] : [],
  includeDistinctScmZone ? [ { name: 'scm', privateDnsZoneResourceId: effectiveScmDnsZoneResourceId } ] : []
)

// Private Endpoint for Python Web App
module webPyPe 'br/public:avm/res/network/private-endpoint:0.11.0' = {
  name: 'pe-${uniqueString(resourceGroup().id, webPythonAppName, 'sites')}'
  params: {
    name: 'pe-${toLower(webPythonAppName)}'
    location: location
    tags: tags
    subnetResourceId: peSubnetId
    privateLinkServiceConnections: [
      {
        name: 'conn-sites'
        properties: {
          privateLinkServiceId: webPy.id
          groupIds: [ 'sites' ]
        }
      }
    ]
    privateDnsZoneGroup: {
      name: 'default'
      privateDnsZoneGroupConfigs: websitesDnsGroupConfigs
    }
  }
}

// Private Endpoint for Next.js Web App
module webNextPe 'br/public:avm/res/network/private-endpoint:0.11.0' = {
  name: 'pe-${uniqueString(resourceGroup().id, webNextAppName, 'sites')}'
  params: {
    name: 'pe-${toLower(webNextAppName)}'
    location: location
    tags: tags
    subnetResourceId: peSubnetId
    privateLinkServiceConnections: [
      {
        name: 'conn-sites'
        properties: {
          privateLinkServiceId: webNext.id
          groupIds: [ 'sites' ]
        }
      }
    ]
    privateDnsZoneGroup: {
      name: 'default'
      privateDnsZoneGroupConfigs: websitesDnsGroupConfigs
    }
  }
}

@description('App Service Plan resource ID')
output planId string = plan.id

@description('Python Web App resource ID')
output webPythonAppId string = webPy.id

@description('Next.js Web App resource ID')
output webNextAppId string = webNext.id

@description('Indicates whether the OpenAI role assignment was attempted (true) or skipped due to invalid/missing ID or toggle (false).')
output openAiRoleAssignmentAttempted bool = oaiValid && createOpenAiRoleAssignment
@description('Indicates the OpenAI resource ID was considered valid for role assignment logic.')
output openAiResourceIdValid bool = oaiValid
