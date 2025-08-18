using './base.bicep'

/*
  base.example.bicepparam
  -----------------------------------------------------------------
  Copy to base.bicepparam (do NOT commit real values to source control).
  Replace <PLACEHOLDERS>. Comment out sections you don't need.

  Conventions:
    - Required values: uncomment & set when enabling associated feature.
    - Optional values: leave commented to accept module defaults / auto-gen.
    - All resource IDs should be full Azure IDs when provided.

  Safe to commit THIS example; do NOT add secrets (keys, connection strings).
  For secrets (Cosmos/Search keys, Function keys, etc.) use Key Vault or
  runtime app settings provisioning – never store in parameter files.
*/

// ------------------------------------------------------------------
// 1. Global / Naming
// ------------------------------------------------------------------
param appNamePrefix = 'dev'                 // Short prefix; final name becomes <prefix>-<stable>
// param tags = { environment: 'dev' owner: 'team-x' }

// ------------------------------------------------------------------
// 2. Networking (optional solution VNet)
//    Enable only if you want the template to create a VNet & subnets.
// ------------------------------------------------------------------
param deploySolutionVnet = true
param solutionVnetName = 'vnet-solution-01' // Or leave '' to auto-generate stable name
param solutionVnetAddressSpace = '10.0.0.0/16'
param flexIntegrationSubnetName = 'flex-integration'
param flexIntegrationSubnetPrefix = '10.0.0.0/24'
param appIntegrationSubnetName = 'app-integration'
param appIntegrationSubnetPrefix = '10.0.1.0/24'
param peSubnetName = 'private-endpoints'
param peSubnetPrefix = '10.0.2.0/24'

// If reusing an EXISTING VNet instead of creating one, set deploySolutionVnet = false
// and provide these explicit subnet resource IDs instead:
// param vnetIntegrationSubnetResourceId = '/subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<delegatedSubnet>'
// param privateEndpointSubnetResourceId = '/subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<peSubnet>'
// param websitesPrivateDnsVnetResourceId = '/subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>'

// ------------------------------------------------------------------
// 3. Shared DNS Zones (optional)
// ------------------------------------------------------------------
// Set to true to create shared blob DNS zone if not supplying an existing zone ID
// param createSharedBlobDnsZone = true
// param sharedBlobPrivateDnsZoneResourceId = '/subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net'
// param sharedBlobDnsZoneVnetResourceId   = '/subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>'

// Cognitive Services shared zone (covers OpenAI & Document Intelligence)
// param createCognitiveServicesDnsZone = true
// param cognitiveServicesPrivateDnsZoneResourceId = '/subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.Network/privateDnsZones/privatelink.cognitiveservices.azure.com'
// param cognitiveServicesDnsZoneVnetResourceId    = '/subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>'
// (linkCognitiveServicesDnsToVnet defaults to true in base.bicep)

// ------------------------------------------------------------------
// 4. Core Function App required app settings (injected via parameters)
//    Provide ONLY the non-discoverable values.
// ------------------------------------------------------------------
// param azureOpenAIDeploymentName = 'gpt-4.1'
// param azureSearchIndexName      = 'chunk'

// ------------------------------------------------------------------
// 5. Feature Toggles
//    Enable features; supply associated params below.
// ------------------------------------------------------------------
param deployLogicApp = true
param deployCosmos = true
param createCosmosDnsZone = true
param deploySearch = true
param createSearchDnsZone = true
param deploySolutionStorage = true
param deployOpenAIPrivateEndpoint = true        // Requires openAIResourceId
param deployDocumentIntelligence = true
param deploySharePointConnection = true         // Logic App must be enabled

// ------------------------------------------------------------------
// 6. Azure OpenAI (existing resource)
//    Provide when using Search Shared Private Link, Private Endpoint, or RBAC.
// ------------------------------------------------------------------
param openAIResourceId = '/subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<openaiAccount>'

// Optional: override Document Intelligence account name (else auto)
// param documentIntelligenceName = 'di-analyze-01'

// ------------------------------------------------------------------
// 7. Cosmos DB (if deployCosmos = true)
// ------------------------------------------------------------------
// param cosmosAccountName = 'cosdemo01'   // Optional override
// param cosmosPrivateEndpointSubnetResourceId = '/subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<peSubnet>'
// param cosmosPrivateDnsZoneResourceId = '/subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.Network/privateDnsZones/privatelink.documents.azure.com'
// param cosmosDnsZoneVnetResourceId = '/subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>'
// param cosmosDatabaseName = 'MainDatabase'
// param cosmosContainerName = 'Documents'
// param cosmosPartitionKeyPath = '/id'

// ------------------------------------------------------------------
// 8. Azure AI Search (if deploySearch = true)
// ------------------------------------------------------------------
// param searchServiceName = 'search-demo01'    // Optional override
// param searchPrivateEndpointSubnetResourceId = '/subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<peSubnet>'
// param searchPrivateDnsZoneResourceId = '/subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.Network/privateDnsZones/privatelink.search.windows.net'
// param searchDnsZoneVnetResourceId = '/subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>'
// param searchSku = 'standard'    // basic|standard|standard2|standard3
// param searchReplicaCount = 1
// param searchPartitionCount = 1

// ------------------------------------------------------------------
// 9. Solution-wide Storage (if deploySolutionStorage = true)
// ------------------------------------------------------------------
// param solutionStorageBlobContainerName = 'shared'
// param solutionStoragePrivateEndpointSubnetResourceId = '/subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<peSubnet>'
// param solutionStorageBlobPrivateDnsZoneResourceId = '/subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net'
// param solutionStorageSku = 'Standard_LRS'

// ------------------------------------------------------------------
// 10. Logic App Standard (if deployLogicApp = true)
// ------------------------------------------------------------------
// param logicAppName = 'las-demo01'
// param logicAppIntegrationSubnetResourceId = '/subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<integrationSubnet>'
// param logicAppVnetResourceId = '/subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>'
// param logicAppStoragePrivateEndpointSubnetResourceId = '/subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<peSubnet>'
// param logicAppStorageAccountName = 'stlogicappdemo'
// param logicAppFileShareName = 'lasruntime'
// param logicAppApplicationInsightsConnectionString = 'InstrumentationKey=<key>;IngestionEndpoint=https://<region>.ingest.monitor.azure.com/'
// param logicAppAdditionalAppSettings = { CUSTOM_SETTING: 'value' }

// ------------------------------------------------------------------
// 11. SharePoint Connection (if deploySharePointConnection = true)
// ------------------------------------------------------------------
// param sharePointConnectionName = 'sharepointonline'
// param sharePointConnectionDisplayName = 'SharePoint (manual auth pending)'

// ------------------------------------------------------------------
// 12. OpenAI Private Endpoint (if deployOpenAIPrivateEndpoint = true)
// ------------------------------------------------------------------
// param openAIPrivateEndpointName = 'oai-pe-01'
// param openAIPrivateEndpointSubnetResourceId = '/subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<peSubnet>'
// param openAIPrivateDnsZoneResourceId = '/subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.Network/privateDnsZones/privatelink.cognitiveservices.azure.com'

// ------------------------------------------------------------------
// 13. Document Intelligence (if deployDocumentIntelligence = true)
// ------------------------------------------------------------------
// param documentIntelligencePrivateEndpointSubnetResourceId = '/subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<peSubnet>'
// param documentIntelligencePrivateDnsZoneResourceId = '/subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.Network/privateDnsZones/privatelink.cognitiveservices.azure.com'

// ------------------------------------------------------------------
// 14. RBAC Notes
//  - Role assignments are created automatically for enabled services using
//    system-assigned identities (no secrets needed here).
// ------------------------------------------------------------------
