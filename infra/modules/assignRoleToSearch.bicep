/**
  Assign a role to a principal at an Azure AI Search scope (same resource group).
*/

targetScope = 'resourceGroup'

@description('Search service name')
param searchServiceName string

@description('Principal objectId (managed identity)')
param principalId string

@description('Role definition ID (GUID)')
param roleDefinitionId string


// Existing Search service
resource search 'Microsoft.Search/searchServices@2023-11-01' existing = {
  name: searchServiceName
}

resource ra 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  // Include principalId for uniqueness across regenerated identities
  name: guid(subscription().id, searchServiceName, principalId, roleDefinitionId)
  scope: search
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
