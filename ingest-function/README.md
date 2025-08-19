# Deploy the ingest Function App (minimal)

## 1) Set required app settings (Azure CLI)

Replace placeholders and run these commands to configure your Function App:

```bash
# Required
az functionapp config appsettings set \
  --name <FUNCTION_APP_NAME> \
  --resource-group <RESOURCE_GROUP> \
  --settings \
  DOC_INTEL_ENDPOINT=https://<doc-intel-name>.cognitiveservices.azure.com/ \
  AZURE_OPENAI_ENDPOINT=https://<openai-name>.openai.azure.com/ \
  AZURE_OPENAI_DEPLOYMENT_NAME=<chat-deployment-name> \
  AZURE_SEARCH_SERVICE_ENDPOINT=https://<search-name>.search.windows.net \
  AZURE_SEARCH_INDEX_NAME=<index-name>

# Optional (if not using Managed Identity)
az functionapp config appsettings set \
  --name <FUNCTION_APP_NAME> \
  --resource-group <RESOURCE_GROUP> \
  --settings \
  DOCUMENT_INTELLIGENCE_KEY=<doc-intel-key>

az functionapp config appsettings set \
  --name <FUNCTION_APP_NAME> \
  --resource-group <RESOURCE_GROUP> \
  --settings \
  AZURE_SEARCH_API_KEY=<search-admin-key>

# Optional (pin Azure OpenAI API version)
az functionapp config appsettings set \
  --name <FUNCTION_APP_NAME> \
  --resource-group <RESOURCE_GROUP> \
  --settings \
  AZURE_OPENAI_API_VERSION=2024-10-21
```

Notes:
- If using Managed Identity, assign roles to the Function App:
  - Document Intelligence: Cognitive Services User
  - Azure AI Search: Search Index Data Contributor (for write)
  - Azure OpenAI: Cognitive Services OpenAI User

## 2) Deploy with Functions Core Tools

From this folder (`ingest-function`), publish the function app:

```bash
# With local settings upload
func azure functionapp publish <FUNCTION_APP_NAME> --build remote --publish-local-settings

# Or without uploading local settings
func azure functionapp publish <FUNCTION_APP_NAME> --build remote
```

## 3) Managed identity and minimal RBAC

Grant the Function App's system-assigned managed identity only the roles it needs:

- Azure AI Search: Search Index Data Contributor (index/read documents)
  - Docs: https://learn.microsoft.com/en-us/azure/search/search-security-rbac#assign-roles
- Document Intelligence: Cognitive Services User (call analyze APIs without keys)
  - Docs: https://learn.microsoft.com/en-us/azure/ai-services/document-intelligence/faq?view=doc-intel-4.0.0#do-i-need-specific-permissions-to-access-document-intelligence-studio
- Azure OpenAI: Cognitive Services OpenAI User (call inference with Entra ID)
  - Docs: https://learn.microsoft.com/en-us/azure/ai-foundry/openai/how-to/role-based-access-control#azure-openai-roles

Enable the Function App identity and assign roles (replace placeholders with your values):

```bash
# Enable system-assigned identity and capture the principalId
principalID=$(az functionapp identity assign \
  --name <FUNCTION_APP_NAME> \
  --resource-group <RESOURCE_GROUP> \
  --identities [system] \
  --query principalId -o tsv)
echo "MSI principalId: $principalID"

# Document Intelligence scope example:
# /subscriptions/<SUB>/resourceGroups/<RG>/providers/Microsoft.CognitiveServices/accounts/<DOC_INTEL_NAME>
az role assignment create \
  --assignee "$principalID" \
  --role "Cognitive Services User" \
  --scope "/subscriptions/<SUB>/resourceGroups/<RG>/providers/Microsoft.CognitiveServices/accounts/<DOC_INTEL_NAME>"

# Azure OpenAI scope example:
# /subscriptions/<SUB>/resourceGroups/<RG>/providers/Microsoft.CognitiveServices/accounts/<OPENAI_NAME>
az role assignment create \
  --assignee "$principalID" \
  --role "Cognitive Services OpenAI User" \
  --scope "/subscriptions/<SUB>/resourceGroups/<RG>/providers/Microsoft.CognitiveServices/accounts/<OPENAI_NAME>"

# Azure AI Search service scope example (covers all indexes):
# /subscriptions/<SUB>/resourceGroups/<RG>/providers/Microsoft.Search/searchServices/<SEARCH_NAME>
az role assignment create \
  --assignee "$principalID" \
  --role "Search Index Data Contributor" \
  --scope "/subscriptions/<SUB>/resourceGroups/<RG>/providers/Microsoft.Search/searchServices/<SEARCH_NAME>"

# Or narrow to a single index:
# /subscriptions/<SUB>/resourceGroups/<RG>/providers/Microsoft.Search/searchServices/<SEARCH_NAME>/indexes/<INDEX_NAME>
az role assignment create \
  --assignee "$principalID" \
  --role "Search Index Data Contributor" \
  --scope "/subscriptions/<SUB>/resourceGroups/<RG>/providers/Microsoft.Search/searchServices/<SEARCH_NAME>/indexes/<INDEX_NAME>"
```

Notes
- Role assignment propagation can take a few minutes.
- If you use API keys instead of managed identity for any service, the corresponding role assignment isn’t required.
