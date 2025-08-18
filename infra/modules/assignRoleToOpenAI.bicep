/**
  Assign a role to a principal at an Azure OpenAI (Cognitive Services) account.
  This module is intended to be deployed at the resource group scope containing the OpenAI account.
*/

targetScope = 'resourceGroup'

@description('Azure OpenAI account name (Microsoft.CognitiveServices/accounts)')
param accountName string

@description('Principal objectId (managed identity)')
param principalId string

@description('Role definition ID (GUID)')
param roleDefinitionId string


// Existing OpenAI account in this resource group scope
resource openAI 'Microsoft.CognitiveServices/accounts@2023-05-01' existing = {
  name: accountName
}

resource ra 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  // Include principalId to ensure new identity gets a fresh assignment instead of update
  name: guid(subscription().id, accountName, principalId, roleDefinitionId)
  scope: openAI
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
