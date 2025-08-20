/**
  Azure Document Intelligence (Form Recognizer) with Private Endpoint and optional Private DNS zone creation
  - Creates Cognitive Services account of kind 'FormRecognizer' via AVM
  - Disables public access, enables system-assigned identity
  - Creates a private endpoint into provided subnet
  - Optionally creates privatelink.cognitiveservices.* Private DNS zone and links to a VNet
*/

targetScope = 'resourceGroup'

@description('Document Intelligence service name')
param name string

@description('Azure location')
param location string = resourceGroup().location

@description('Private endpoint subnet resource ID')
param peSubnetId string

@description('Existing Cognitive Services Private DNS zone resource ID (privatelink.cognitiveservices.*). If empty and createDnsZone=true, a zone will be created and linked to the VNet')
param cognitiveServicesPrivateDnsZoneId string = ''

@description('Set to true to create the Cognitive Services Private DNS zone and link it to a VNet when no zone ID is provided')
param createDnsZone bool = false

@description('VNet resource ID to link the Private DNS zone (required when createDnsZone=true and no zone ID provided)')
param dnsZoneVnetResourceId string = ''

@description('Cognitive Services Private DNS zone name')
param dnsZoneName string = 'privatelink.cognitiveservices.azure.com'

@description('SKU for Document Intelligence (F0 = Free, S0 = Standard)')
@allowed(['F0', 'S0'])
param sku string = 'S0'

@description('Tags to apply')
param tags object = {}


// Optionally create Private DNS zone and VNet link using AVM
module dns 'br/public:avm/res/network/private-dns-zone:0.7.0' = if (createDnsZone && empty(cognitiveServicesPrivateDnsZoneId)) {
  name: 'dns-cogsvc-${uniqueString(resourceGroup().id, name)}'
  params: {
    name: dnsZoneName
    tags: tags
    virtualNetworkLinks: [
      {
        name: 'link-cogsvc-${take(uniqueString(resourceGroup().id, name), 8)}'
        virtualNetworkResourceId: dnsZoneVnetResourceId
        registrationEnabled: false
      }
    ]
  }
}

var effectiveDnsZoneId = !empty(cognitiveServicesPrivateDnsZoneId) ? cognitiveServicesPrivateDnsZoneId : resourceId('Microsoft.Network/privateDnsZones', dnsZoneName)

// Deploy Azure Document Intelligence using Azure Verified Module
module documentIntelligence 'br/public:avm/res/cognitive-services/account:0.13.0' = {
  name: 'di-${uniqueString(resourceGroup().id, name)}'
  params: {
    name: name
    location: location
    kind: 'FormRecognizer'
    sku: sku
    tags: tags
  // Re-introduced: ensure CustomSubDomainName exists (using same value as account name for consistency)
  customSubDomainName: name

    // Networking and security
    publicNetworkAccess: 'Disabled'
    disableLocalAuth: false
    restrictOutboundNetworkAccess: true

    // Private endpoint configuration
    privateEndpoints: [
      {
        name: '${toLower(name)}-pe'
        subnetResourceId: peSubnetId
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              name: 'cognitive-services'
              privateDnsZoneResourceId: effectiveDnsZoneId
            }
          ]
        }
        tags: tags
      }
    ]

    // Identity
    managedIdentities: {
      systemAssigned: true
    }
  }
}

// Outputs
output resourceId string = documentIntelligence.outputs.resourceId
output name string = documentIntelligence.outputs.name
output endpoint string = documentIntelligence.outputs.endpoint
output systemAssignedMIPrincipalId string = documentIntelligence.outputs.systemAssignedMIPrincipalId!
// Private endpoint FQDN will resolve via standard pattern using the resource name
output privateEndpointFqdn string = '${name}.privatelink.cognitiveservices.azure.com'
