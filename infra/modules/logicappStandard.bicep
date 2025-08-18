/**
  Logic App Standard (single-tenant) consolidated module
  - Creates Workflow Standard plan (WS1 Windows)
  - Provisions StorageV2 with Azure Files share (connection-string based)
  - Creates Private Endpoints for blob and file with Private DNS zones + VNet link
  - Creates the Logic App Standard site with required app settings and VNet integration
  - App Insights is optional via connection string

  AVM usage: storage account, private endpoints, private DNS zones
*/

@description('Logic App Standard site name')
param name string

@description('Azure location')
param location string

@description('Tags to apply')
param tags object = {}

@description('Integration subnet resource ID (regional VNet integration)')
param integrationSubnetId string

@description('Virtual Network resource ID used to link the Private DNS zones for Storage')
param vnetResourceId string

@description('Subnet resource ID to place the Storage Private Endpoints (blob, file)')
param storagePrivateEndpointSubnetResourceId string

@description('Optional Storage account name (lowercase, alphanumeric, <=24). If empty, a name is generated')
param storageAccountName string = ''

@description('Azure Files share name for WEBSITE_CONTENTSHARE')
param fileShareName string = 'lasruntime'

@description('Optional Application Insights connection string')
param applicationInsightsConnectionString string = ''

@description('Optional additional app settings as an object map, e.g., { "KEY": "value" }')
param additionalAppSettings object = {}

@description('Workflow Standard plan name')
param planName string = 'la-ws-${toLower(take(uniqueString(resourceGroup().id, name), 8))}'

@description('Optional existing Private DNS zone resource ID for blob (privatelink.blob.*). If empty, a zone will be created and linked to the provided VNet')
param blobPrivateDnsZoneResourceId string = ''

@description('Optional existing Private DNS zone resource ID for file (privatelink.file.*). If empty, a zone will be created and linked to the provided VNet')
param filePrivateDnsZoneResourceId string = ''

@description('Optional existing Private DNS zone resource ID for queue (privatelink.queue.*). If empty, a zone will be created and linked to the provided VNet')
param queuePrivateDnsZoneResourceId string = ''

@description('Optional existing Private DNS zone resource ID for table (privatelink.table.*). If empty, a zone will be created and linked to the provided VNet')
param tablePrivateDnsZoneResourceId string = ''

@description('Skip creating a VNet link for the blob private DNS zone (use when parent deployment already created and linked zone)')
param skipBlobDnsLink bool = false

// additionalAppSettings is already an object map; we'll merge it directly in the child config

// Storage name (generated if not provided). Include Logic App name for readability and add deterministic suffix for uniqueness
var lasPrefix = toLower(take(replace(replace(replace(name, '-', ''), '_', ''), '.', ''), 10))
var lasSuffix = toLower(take(uniqueString(subscription().id, resourceGroup().id, name, 'las-stg'), 8))
var stgName = !empty(storageAccountName) ? toLower(storageAccountName) : 'st${lasPrefix}${lasSuffix}'

// Consolidated service definitions for storage private endpoints
var storageSuffix = environment().suffixes.storage // e.g., core.windows.net
var shortSuffix = toLower(take(uniqueString(resourceGroup().id, name), 8))
var storageServices = [
  {
    key: 'blob'
    zoneParam: blobPrivateDnsZoneResourceId
  }
  {
    key: 'file'
    zoneParam: filePrivateDnsZoneResourceId
  }
  {
    key: 'queue'
    zoneParam: queuePrivateDnsZoneResourceId
  }
  {
    key: 'table'
    zoneParam: tablePrivateDnsZoneResourceId
  }
]

// ---------------------------------------------------------------------------
// App Service plan: Workflow Standard WS1 (Windows)
// ---------------------------------------------------------------------------
resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  tags: tags
  kind: 'elastic'
  sku: {
    tier: 'WorkflowStandard'
    name: 'WS1'
    capacity: 1
  }
  properties: {
    reserved: false
    perSiteScaling: false
  }
}

// ---------------------------------------------------------------------------
// Storage account with Azure Files share (AVM)
// ---------------------------------------------------------------------------
module stg 'br/public:avm/res/storage/storage-account:0.26.0' = {
  name: 'stg-${uniqueString(resourceGroup().id, name)}'
  params: {
    name: stgName
    location: location
    tags: tags
    kind: 'StorageV2'
    skuName: 'Standard_LRS'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowSharedKeyAccess: true
    publicNetworkAccess: 'Disabled'
    // Pre-create host/secrets containers to reduce first-start races
    blobServices: {
      containers: [
        {
          name: 'azure-webjobs-hosts'
          publicAccess: 'None'
        }
        {
          name: 'azure-webjobs-secrets'
          publicAccess: 'None'
        }
      ]
    }
    fileServices: {
      shares: [
        {
          name: fileShareName
          enabledProtocols: 'SMB'
          shareQuota: 100
          accessTier: 'TransactionOptimized'
        }
      ]
    }
  }
}

// ---------------------------------------------------------------------------
// Inline Private DNS zones & virtual network links (blob, file, queue, table)
// ---------------------------------------------------------------------------
resource dnsZones 'Microsoft.Network/privateDnsZones@2020-06-01' = [for s in storageServices: if (empty(s.zoneParam)) {
  name: 'privatelink.${s.key}.${storageSuffix}'
  location: 'global'
  tags: tags
}]

// Create or update VNet links for each zone (works for existing zones too)
resource dnsLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for (s, i) in storageServices: if (!(skipBlobDnsLink && s.key == 'blob' && !empty(s.zoneParam))) {
  name: '${empty(s.zoneParam) ? dnsZones[i].name : format('privatelink.{0}.{1}', s.key, storageSuffix)}/link-${s.key}-${shortSuffix}'
  // Fix concatenation using interpolation to satisfy Bicep type system
  // (Original attempted '+' concatenation on union type)
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetResourceId
    }
  }
  dependsOn: [
    ...(empty(s.zoneParam) ? [ dnsZones[i] ] : [])
  ]
}]

// ---------------------------------------------------------------------------
// Inline Private Endpoints for each storage service with DNS zone groups
// ---------------------------------------------------------------------------
resource privateEndpoints 'Microsoft.Network/privateEndpoints@2023-05-01' = [for (s, i) in storageServices: {
  name: 'pe-${toLower(stgName)}-${s.key}'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: storagePrivateEndpointSubnetResourceId
    }
    privateLinkServiceConnections: [
      {
        name: 'pls-${s.key}'
        properties: {
          privateLinkServiceId: stg.outputs.resourceId
          groupIds: [ s.key ]
        }
      }
    ]
  }
  dependsOn: [ dnsLinks[i] ]
}]

// Attach DNS zone groups to each private endpoint (child resources)
resource peDnsZoneGroups 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-05-01' = [for (s, i) in storageServices: {
  name: '${privateEndpoints[i].name}/default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: s.key
        properties: {
          privateDnsZoneId: empty(s.zoneParam) ? resourceId('Microsoft.Network/privateDnsZones', 'privatelink.${s.key}.${storageSuffix}') : s.zoneParam
        }
      }
    ]
  }
  dependsOn: [ privateEndpoints[i] ]
}]

// Connection strings will be computed inline inside the site resource to respect dependency on storage

// ---------------------------------------------------------------------------
// Logic App Standard site
// ---------------------------------------------------------------------------
resource site 'Microsoft.Web/sites@2023-12-01' = {
  name: name
  location: location
  tags: tags
  kind: 'functionapp,workflowapp'
  identity: {
    type: 'SystemAssigned'
  }
  // Ensure all storage private endpoints are in place before site mounts content share (public access disabled)
  dependsOn: [ stg, peDnsZoneGroups ]
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    virtualNetworkSubnetId: integrationSubnetId
  // Enable mounting the content (Azure Files) share via private endpoints / VNet
  vnetContentShareEnabled: true
    siteConfig: {
      // 64-bit worker
      use32BitWorkerProcess: false
      // Allocate private ports for VNet integration as requested
      vnetPrivatePortsCount: 2
    }
  }
}

// Move app settings to a dedicated child config to strictly sequence after storage & site exist
resource siteAppSettings 'Microsoft.Web/sites/config@2023-12-01' = {
  name: 'appsettings'
  parent: site
  properties: union(
    {
  // Use the AVM storage module's secure output connection string to avoid transient listKeys race
  WEBSITE_CONTENTAZUREFILECONNECTIONSTRING: stg.outputs.primaryConnectionString
  AzureWebJobsStorage: stg.outputs.primaryConnectionString
      WEBSITE_CONTENTSHARE: fileShareName
      WEBSITE_CONTENTOVERVNET: '1'
      WEBSITE_VNET_ROUTE_ALL: '1'
  FUNCTIONS_INPROC_NET8_ENABLED: '1'
      APP_KIND: 'workflowApp'
      FUNCTIONS_WORKER_RUNTIME: 'dotnet'
      FUNCTIONS_EXTENSION_VERSION: '~4'
      AzureFunctionsJobHost__extensionBundle__id: 'Microsoft.Azure.Functions.ExtensionBundle.Workflows'
      AzureFunctionsJobHost__extensionBundle__version: '[1.*, 2.0.0)'
      WEBSITE_NODE_DEFAULT_VERSION: '~20'
    },
    applicationInsightsConnectionString != '' ? { APPLICATIONINSIGHTS_CONNECTION_STRING: applicationInsightsConnectionString } : {},
    additionalAppSettings
  )
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output siteName string = site.name
output planId string = plan.id
output storageAccountId string = stg.outputs.resourceId
output storageAccountName string = stgName
output fileShare string = fileShareName
output principalId string = site.identity.principalId!
