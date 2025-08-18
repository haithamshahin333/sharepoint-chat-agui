targetScope = 'resourceGroup'

@description('Storage account name in this resource group')
param storageAccountName string

@description('Principal ID (objectId) to assign role to')
param principalId string

@description('Role definition resource ID (subscriptionResourceId to the role)')
param roleDefinitionId string

resource stg 'Microsoft.Storage/storageAccounts@2023-01-01' existing = {
  name: storageAccountName
}

resource roleAssign 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(stg.id, roleDefinitionId, principalId)
  scope: stg
  properties: {
    roleDefinitionId: roleDefinitionId
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
