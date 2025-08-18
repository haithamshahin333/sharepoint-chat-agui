targetScope = 'resourceGroup'

@description('Azure AI Search service name in this resource group')
param searchServiceName string

@description('Principal ID (objectId) to assign role to')
param principalId string

@description('Role definition resource ID (subscriptionResourceId to the role)')
param roleDefinitionId string

resource sea 'Microsoft.Search/searchServices@2023-11-01' existing = {
  name: searchServiceName
}

resource roleAssign 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sea.id, roleDefinitionId, principalId)
  scope: sea
  properties: {
    roleDefinitionId: roleDefinitionId
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
