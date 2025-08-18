/**
  Module: SharePoint Online API Connection (manual delegated auth)
  Creates the Microsoft.Web/connections resource for the SharePoint Online managed connector
  plus an access policy granting the Logic App's system-assigned managed identity permission
  to use the connection at runtime.
*/

@description('Azure region (must match Logic App region for managed connector).')
param location string

@description('Connection resource name (e.g. sharepointonline).')
param name string

@description('Display name shown in the portal prior to authorization.')
param displayName string

@description('Tags to apply to the connection.')
param tags object = {}

@description('Logic App system-assigned managed identity objectId used for access policy.')
param logicAppPrincipalObjectId string


// SharePoint Online connection (unauthenticated until portal sign-in)
resource spoConnection 'Microsoft.Web/connections@2016-06-01' = {
  name: name
  kind: 'V2'
  location: location
  tags: tags
  properties: {
    displayName: displayName
    api: {
      id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'sharepointonline')
    }
    // Empty parameter values (delegated auth will be completed manually)
    parameterValues: {}
    nonSecretParameterValues: {}
    customParameterValues: {}
  }
}

// Access policy granting the Logic App identity permission to use this connection (V2 only)
resource accessPolicy 'Microsoft.Web/connections/accessPolicies@2016-06-01' = {
  name: logicAppPrincipalObjectId
  location: location
  parent: spoConnection
  properties: {
    principal: {
      type: 'ActiveDirectory'
      identity: {
        objectId: logicAppPrincipalObjectId
        tenantId: tenant().tenantId
      }
    }
  }
}

output connectionId string = spoConnection.id
