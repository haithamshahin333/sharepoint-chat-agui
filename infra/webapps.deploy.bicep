/**
  Web Apps only deployment: centralized Websites Private DNS (web + scm) and the Web Apps module
  (shared App Service Plan + two Linux Web Apps + Private Endpoints), using existing VNet/subnets.
*/

@description('Primary region for all resources')
param location string = resourceGroup().location

@description('Resource tags')
param tags object = {}

@description('Set to true to deploy a shared App Service Plan and two Web Apps (Python + Next.js) with VNet integration and Private Endpoints')
param deployWebApps bool = true

@description('Optional: App Service Plan name (if empty, a stable name will be generated)')
param appServicePlanName string = ''

@description('App Service Plan SKU name (e.g., P1v3, P2v3). Tier will be inferred as PremiumV3')
param appServicePlanSku string = 'P1v3'

@description('Optional: Python web app name (if empty, a stable name will be generated)')
param webPythonAppName string = ''

@description('Optional: Next.js web app name (if empty, a stable name will be generated)')
param webNextAppName string = ''

@description('Node LTS version for Next.js (e.g., 22-lts, 20-lts)')
param nodeLts string = '22-lts'

@description('Resource ID of the VNet hosting the integration and PE subnets')
param vnetResourceId string

@description('Name of the App/Logic integration subnet in the VNet')
param appIntegrationSubnetName string = 'app-integration'

@description('Name of the Private Endpoints subnet in the VNet')
param peSubnetName string = 'private-endpoints'

@description('Existing Private DNS zone resource ID for privatelink.azurewebsites.net. If empty and vnetResourceId is provided, a zone will be created and linked')
param privateDnsZoneWebsitesResourceIdForWebApps string = ''

@description('Existing Private DNS zone resource ID for privatelink.scm.azurewebsites.net. If empty and vnetResourceId is provided, a zone will be created and linked')
param privateDnsZoneWebsitesScmResourceId string = ''

@description('Unique suffix for nested deployment names; defaults to a 6-char GUID fragment')
param deploymentInstance string = toLower(take(replace(newGuid(), '-', ''), 6))

// Optional: Resource IDs for role assignments on the backend web app (SystemAssigned identity)
@description('Resource ID of the target Storage Account to assign Storage Blob Data Reader to the backend web app (optional)')
param storageAccountResourceId string = ''

@description('Resource ID of the Azure AI Search service to assign Search Index Data Reader to the backend web app (optional)')
param searchServiceResourceId string = ''

@description('Resource ID of the Azure OpenAI (Cognitive Services) account to assign Cognitive Services OpenAI User to the backend web app (optional)')
param openAiAccountResourceId string = ''

// Optional toggles to skip creating role assignments (useful when assignments already exist)
@description('Create Storage Blob Data Reader assignment for backend web app (default true)')
param createStorageRoleAssignment bool = true
@description('Create Search Index Data Reader assignment for backend web app (default true)')
param createSearchRoleAssignment bool = true
@description('Create Cognitive Services OpenAI User assignment for backend web app (default true)')
param createOpenAiRoleAssignment bool = true

var websitesDnsZoneName = 'privatelink.azurewebsites.net'
var websitesScmDnsZoneName = 'privatelink.scm.azurewebsites.net'

var appIntegrationSubnetId = '${vnetResourceId}/subnets/${appIntegrationSubnetName}'
var peSubnetId = '${vnetResourceId}/subnets/${peSubnetName}'

var createWebsitesDnsZone = deployWebApps && empty(privateDnsZoneWebsitesResourceIdForWebApps) && !empty(vnetResourceId)
// Only create the SCM zone if neither a preexisting SCM zone nor a main websites zone is supplied
// (when a main websites zone is supplied, we reuse it for scm records)
var createWebsitesScmDnsZone = deployWebApps && empty(privateDnsZoneWebsitesScmResourceId) && empty(privateDnsZoneWebsitesResourceIdForWebApps) && !empty(vnetResourceId)

module websitesDns 'modules/privateDnsWebsites.bicep' = if (createWebsitesDnsZone) {
  name: 'dns-websites-${uniqueString(resourceGroup().id, deploymentInstance)}'
  params: {
    dnsZoneName: websitesDnsZoneName
    vnetResourceId: vnetResourceId
    vnetLinkName: 'link-web-${take(uniqueString(resourceGroup().id), 6)}'
    tags: tags
  }
}

module websitesScmDns 'modules/privateDnsWebsites.bicep' = if (createWebsitesScmDnsZone) {
  name: 'dns-websites-scm-${uniqueString(resourceGroup().id, deploymentInstance)}'
  params: {
    dnsZoneName: websitesScmDnsZoneName
    vnetResourceId: vnetResourceId
    vnetLinkName: 'link-scm-${take(uniqueString(resourceGroup().id), 6)}'
    tags: tags
  }
}

var effectiveWebsitesDnsZoneResourceId = !empty(privateDnsZoneWebsitesResourceIdForWebApps)
  ? privateDnsZoneWebsitesResourceIdForWebApps
  : (createWebsitesDnsZone ? resourceId('Microsoft.Network/privateDnsZones', websitesDnsZoneName) : '')

var effectiveWebsitesScmDnsZoneResourceId = !empty(privateDnsZoneWebsitesScmResourceId)
  ? privateDnsZoneWebsitesScmResourceId
  : (createWebsitesScmDnsZone ? resourceId('Microsoft.Network/privateDnsZones', websitesScmDnsZoneName) : '')

// Effective names
var effectivePlanName = !empty(appServicePlanName) ? appServicePlanName : 'plan-${uniqueString(resourceGroup().id, 'webapps')}'
var effectiveWebPythonName = !empty(webPythonAppName) ? webPythonAppName : 'py${uniqueString(resourceGroup().id, 'webpy')}'
var effectiveWebNextName = !empty(webNextAppName) ? webNextAppName : 'nx${uniqueString(resourceGroup().id, 'webnx')}'

module webapps 'modules/webApps.bicep' = if (deployWebApps) {
  name: 'webapps-${uniqueString(resourceGroup().id, 'webappsmod')}'
  dependsOn: [
    ...(createWebsitesDnsZone ? [ websitesDns ] : [])
    ...(createWebsitesScmDnsZone ? [ websitesScmDns ] : [])
  ]
  params: {
    location: location
    tags: tags
    planName: effectivePlanName
    planSku: appServicePlanSku
    webPythonAppName: effectiveWebPythonName
    webNextAppName: effectiveWebNextName
    nodeLts: nodeLts
    appIntegrationSubnetId: appIntegrationSubnetId
    peSubnetId: peSubnetId
    websitesDnsZoneResourceId: effectiveWebsitesDnsZoneResourceId
    websitesScmDnsZoneResourceId: effectiveWebsitesScmDnsZoneResourceId
  // Optional MI role assignments (leave empty to skip)
  storageAccountResourceId: storageAccountResourceId
  searchServiceResourceId: searchServiceResourceId
  openAiAccountResourceId: openAiAccountResourceId
  createStorageRoleAssignment: createStorageRoleAssignment
  createSearchRoleAssignment: createSearchRoleAssignment
  createOpenAiRoleAssignment: createOpenAiRoleAssignment
  }
}
