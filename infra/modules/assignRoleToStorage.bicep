/**
  Assign a role to a principal at a Storage Account scope (same resource group).
*/

targetScope = 'resourceGroup'

@description('Storage account name')
param storageAccountName string

@description('Principal objectId (managed identity)')
param principalId string

@description('Role definition ID (GUID)')
param roleDefinitionId string


// Existing Storage account
resource stg 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

// Role assignment (extension resource scoped to the storage account)
resource ra 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  // Include principalId in deterministic name so a regenerated managed identity produces a new role assignment
  name: guid(subscription().id, storageAccountName, principalId, roleDefinitionId)
  scope: stg
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
