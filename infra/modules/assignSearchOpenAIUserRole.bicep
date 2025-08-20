targetScope = 'resourceGroup'

@description('Name of the existing Azure OpenAI (Cognitive Services) account')
param openAIAccountName string

@description('Principal ID (objectId) of the Azure AI Search managed identity')
param searchPrincipalId string

// Cognitive Services OpenAI User role definition ID
var roleDefId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')

// Existing OpenAI account in this scope
resource openAIAccount 'Microsoft.CognitiveServices/accounts@2023-05-01' existing = {
  name: openAIAccountName
}

// Stable name not relying on runtime principalId (name must be start-time evaluable)
// Including the principalId would violate early-eval constraints if passed from parent module outputs in name.
resource searchOpenAIUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(openAIAccount.id, roleDefId, 'search-mi-openai-user')
  scope: openAIAccount
  properties: {
    roleDefinitionId: roleDefId
    principalId: searchPrincipalId
    principalType: 'ServicePrincipal'
  }
}
