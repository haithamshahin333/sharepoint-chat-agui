/**
  Module: Private DNS zone for Azure Websites + VNet link
  - Creates privatelink.azurewebsites.net zone (via AVM)
  - Optionally links it to the provided VNet resource ID
  - If vnetResourceId is empty, no resources are created and an empty output is returned
*/

@description('Name of the Private DNS zone for Azure Websites. Defaults to privatelink.azurewebsites.net')
param dnsZoneName string = 'privatelink.azurewebsites.net'

@description('Resource ID of the Virtual Network to link to the Private DNS zone')
param vnetResourceId string

@description('Name of the VNet link resource')
param vnetLinkName string

@description('Tags to apply')
param tags object = {}

var enabled = !empty(vnetResourceId)

// Use Azure Verified Module for Private DNS Zone; deploy only when enabled
module pdns 'br/public:avm/res/network/private-dns-zone:0.7.0' = if (enabled) {
  name: 'pdns-${uniqueString(dnsZoneName)}'
  params: {
    name: dnsZoneName
    tags: tags
    virtualNetworkLinks: [
      {
        name: vnetLinkName
        virtualNetworkResourceId: vnetResourceId
        registrationEnabled: false
      }
    ]
  }
}

// Avoid referencing conditional module outputs directly to satisfy Bicep analysis
output dnsZoneResourceId string = enabled ? resourceId('Microsoft.Network/privateDnsZones', dnsZoneName) : ''
