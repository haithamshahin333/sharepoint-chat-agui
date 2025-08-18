targetScope = 'resourceGroup'

@description('Azure OpenAI (Cognitive Services) account name in this resource group')
param openAiAccountName string

@description('Principal ID (objectId) to assign role to')
param principalId string

@description('Role definition resource ID (subscriptionResourceId to the role)')
param roleDefinitionId string

resource oai 'Microsoft.CognitiveServices/accounts@2023-05-01' existing = {
  name: openAiAccountName
}

resource roleAssign 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(oai.id, roleDefinitionId, principalId)
  scope: oai
  properties: {
    roleDefinitionId: roleDefinitionId
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
