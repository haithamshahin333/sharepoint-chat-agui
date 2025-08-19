#!/usr/bin/env bash
# Deploy Logic App Standard workflows & parameterized connections.
# - Loads .env
# - Discovers function host name & shared key
# - Discovers SharePoint connection runtime URL
# - Upserts required app settings
# - Deploys workflows zip
# - Optionally opens/closes network for TEMP_ALLOW_IP

set -euo pipefail

# Optional debug tracing
[[ "${DEBUG:-}" == "1" ]] && set -x

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
workflows_dir="$repo_root/../ingest-workflow"
# connections.json now maintained directly; no template copy step required.

load_env() {
  local env_file="$script_dir/.env"
  [[ -f "$env_file" ]] || { echo "[env] No .env file found at $env_file"; return; }
  echo "[env] Loading variables from $env_file"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" == *" #"* ]] && line="${line%% #*}"
    # trim outer whitespace
    line="${line#${line%%[![:space:]]*}}"; line="${line%${line##*[![:space:]]}}"
    [[ "$line" != *"="* ]] && continue
    local key="${line%%=*}"; local val="${line#*=}"
    key="${key#${key%%[![:space:]]*}}"; key="${key%${key##*[![:space:]]}}"
    val="${val#${val%%[![:space:]]*}}"; val="${val%${val##*[![:space:]]}}"
    # strip matching single or double quotes
    if [[ "$val" == "\""*"\"" && "$val" == *"\"" ]]; then
      val="${val:1:${#val}-2}"
    elif [[ "$val" == "'"*"'" && "$val" == *"'" ]]; then
      val="${val:1:${#val}-2}"
    fi
    [[ -z "${!key:-}" ]] && export "$key=$val"
  done < "$env_file"
}

require_env() { local v="$1"; [[ -n "${!v:-}" ]] || { echo "[error] Required variable $v not set" >&2; exit 1; }; }

fetch_function_metadata() {
  echo "[discover] Function hostname & host key"
  FUNCTION_APP_DEFAULT_HOSTNAME=$(az functionapp show --name "$FUNCTION_APP_NAME" --resource-group "$FUNCTION_RESOURCE_GROUP" --query "defaultHostName" -o tsv 2>/dev/null || echo "")
  if [[ -z "$FUNCTION_APP_DEFAULT_HOSTNAME" ]]; then
    echo "[warn] defaultHostName empty from az functionapp show; attempting alternate query"
    FUNCTION_APP_DEFAULT_HOSTNAME=$(az resource show --resource-group "$FUNCTION_RESOURCE_GROUP" --resource-type Microsoft.Web/sites --name "$FUNCTION_APP_NAME" --query "properties.defaultHostName" -o tsv 2>/dev/null || echo "")
  fi
  if [[ -z "$FUNCTION_APP_DEFAULT_HOSTNAME" ]]; then
    # Construct conventional hostname as last resort
    FUNCTION_APP_DEFAULT_HOSTNAME="${FUNCTION_APP_NAME}.azurewebsites.net"
    echo "[warn] Using constructed hostname fallback: $FUNCTION_APP_DEFAULT_HOSTNAME (verify reachability)"
  else
    echo "[discover] defaultHostName=$FUNCTION_APP_DEFAULT_HOSTNAME"
  fi
  if [[ -z "${azureFunctionOperation_functionAppKey:-}" ]]; then
    azureFunctionOperation_functionAppKey=$(az rest --method post --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$FUNCTION_RESOURCE_GROUP/providers/Microsoft.Web/sites/$FUNCTION_APP_NAME/host/default/listkeys?api-version=2023-01-01" --query "functionKeys.default" -o tsv 2>/dev/null || echo "")
    if [[ -z "$azureFunctionOperation_functionAppKey" ]]; then
      azureFunctionOperation_functionAppKey=$(az rest --method post --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$FUNCTION_RESOURCE_GROUP/providers/Microsoft.Web/sites/$FUNCTION_APP_NAME/host/default/listkeys?api-version=2023-01-01" --query "masterKey" -o tsv 2>/dev/null || echo "")
    fi
    [[ -n "$azureFunctionOperation_functionAppKey" ]] && export azureFunctionOperation_functionAppKey && echo "[discover] Retrieved shared function host key" || echo "[warn] Could not retrieve function host key"
  else
    echo "[discover] azureFunctionOperation_functionAppKey already provided"
  fi
}

fetch_sharepoint_connection_runtime_url() {
  [[ -z "${SHAREPOINT_CONNECTION_RUNTIME_URL:-}" ]] || { echo "[discover] SHAREPOINT_CONNECTION_RUNTIME_URL already provided"; return; }
  [[ -n "${SHAREPOINT_CONNECTION_NAME:-}" && -n "${SHAREPOINT_CONNECTION_RG:-}" ]] || { echo "[discover] Skipping runtime URL lookup (name or RG not set)"; return; }
  echo "[discover] Fetching SharePoint connection runtime URL"
  SHAREPOINT_CONNECTION_RUNTIME_URL=$(az resource show --ids "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$SHAREPOINT_CONNECTION_RG/providers/Microsoft.Web/connections/$SHAREPOINT_CONNECTION_NAME" --query "properties.connectionRuntimeUrl" -o tsv 2>/dev/null || echo "")
  [[ -n "$SHAREPOINT_CONNECTION_RUNTIME_URL" ]] && export SHAREPOINT_CONNECTION_RUNTIME_URL && echo "[discover] SHAREPOINT_CONNECTION_RUNTIME_URL=$SHAREPOINT_CONNECTION_RUNTIME_URL" || echo "[warn] Could not determine SHAREPOINT_CONNECTION_RUNTIME_URL"
}

discover_openai_endpoint() {
  if [[ -n "${openai_openAIEndpoint:-}" ]]; then
    echo "[discover] Using openai_openAIEndpoint from .env: $openai_openAIEndpoint"
    return
  fi
  if [[ -n "${OPENAI_ENDPOINT:-}" ]]; then
    # Directly use provided OPENAI_ENDPOINT value
    openai_openAIEndpoint="${OPENAI_ENDPOINT%/}"
    export openai_openAIEndpoint
    echo "[discover] Mapped OPENAI_ENDPOINT -> openai_openAIEndpoint=$openai_openAIEndpoint"
    return
  fi
  echo "[discover] No OPENAI_ENDPOINT (and no openai_openAIEndpoint) provided; skipping OpenAI app setting"
}

discover_search_endpoint() {
  # Existing logic handled earlier; consolidate here to ensure it always runs before collection
  if [[ -n "${azureaisearch_searchServiceEndpoint:-}" ]]; then
    echo "[discover] azureaisearch_searchServiceEndpoint already set (${azureaisearch_searchServiceEndpoint})"
    return
  fi
  # Direct mapping from AZURE_SEARCH_ENDPOINT if present
  if [[ -n "${AZURE_SEARCH_ENDPOINT:-}" ]]; then
    azureaisearch_searchServiceEndpoint="${AZURE_SEARCH_ENDPOINT%/}"
    export azureaisearch_searchServiceEndpoint
    echo "[discover] Mapped AZURE_SEARCH_ENDPOINT -> azureaisearch_searchServiceEndpoint=${azureaisearch_searchServiceEndpoint}"
    return
  fi
  local svc="${SEARCH_SERVICE_NAME:-${AZURE_SEARCH_SERVICE_NAME:-}}"
  if [[ -n "$svc" ]]; then
    azureaisearch_searchServiceEndpoint="https://${svc}.search.windows.net"
    export azureaisearch_searchServiceEndpoint
    echo "[discover] Derived azureaisearch_searchServiceEndpoint=$azureaisearch_searchServiceEndpoint (from service name)"
  else
    echo "[discover] Skipping search endpoint (no azureaisearch_searchServiceEndpoint, AZURE_SEARCH_ENDPOINT, or service name vars)"
  fi
}

discover_cosmos_connection_string() {
  if [[ -n "${AzureCosmosDB_connectionString:-}" ]]; then
    echo "[discover] AzureCosmosDB_connectionString already set (len=${#AzureCosmosDB_connectionString})"
    return
  fi
  # Direct mapping from conventional env var names if provided
  if [[ -n "${COSMOS_CONNECTION_STRING:-}" ]]; then
    AzureCosmosDB_connectionString="$COSMOS_CONNECTION_STRING"
    export AzureCosmosDB_connectionString
    echo "[discover] Mapped COSMOS_CONNECTION_STRING -> AzureCosmosDB_connectionString (len=${#AzureCosmosDB_connectionString})"
    return
  fi
  if [[ -n "${AZURE_COSMOS_CONNECTION_STRING:-}" ]]; then
    AzureCosmosDB_connectionString="$AZURE_COSMOS_CONNECTION_STRING"
    export AzureCosmosDB_connectionString
    echo "[discover] Mapped AZURE_COSMOS_CONNECTION_STRING -> AzureCosmosDB_connectionString (len=${#AzureCosmosDB_connectionString})"
    return
  fi
  local acct="${COSMOS_ACCOUNT_NAME:-}" rg="${COSMOS_ACCOUNT_RG:-${RESOURCE_GROUP:-}}"
  if [[ -z "$acct" || -z "$rg" ]]; then
    echo "[discover] Skipping Cosmos discover (no connection string or account vars)"
    return
  fi
  echo "[discover] Fetching Cosmos DB primary SQL connection string for $acct"
  AzureCosmosDB_connectionString=$(az cosmosdb keys list --name "$acct" --resource-group "$rg" --type connection-strings --query "connectionStrings[?contains(description, 'Primary SQL')].connectionString | [0]" -o tsv 2>/dev/null || echo "")
  if [[ -z "$AzureCosmosDB_connectionString" ]]; then
    AzureCosmosDB_connectionString=$(az cosmosdb keys list --name "$acct" --resource-group "$rg" --type connection-strings --query "connectionStrings[0].connectionString" -o tsv 2>/dev/null || echo "")
  fi
  if [[ -n "$AzureCosmosDB_connectionString" ]]; then
    export AzureCosmosDB_connectionString
    echo "[discover] Retrieved Cosmos DB connection string (len=${#AzureCosmosDB_connectionString})"
  else
    echo "[warn] Could not retrieve Cosmos DB connection string"
  fi
}

discover_blob_endpoint() {
  # Simplified: only derive from STORAGE_ACCOUNT_MIRROR_NAME
  if [[ -z "${STORAGE_ACCOUNT_MIRROR_NAME:-}" ]]; then
    echo "[discover] STORAGE_ACCOUNT_MIRROR_NAME not set; skipping blob endpoint"
    return
  fi
  AzureBlob_blobStorageEndpoint="https://${STORAGE_ACCOUNT_MIRROR_NAME}.blob.core.windows.net"
  export AzureBlob_blobStorageEndpoint
  echo "[discover] Set AzureBlob_blobStorageEndpoint=$AzureBlob_blobStorageEndpoint"
}

# Attempt to discover a Cosmos DB account name if none provided and no connection string already resolved.
auto_discover_cosmos_account() {
  [[ -n "${COSMOS_ACCOUNT_NAME:-}" ]] && return 0
  [[ -n "${AzureCosmosDB_connectionString:-${COSMOS_CONNECTION_STRING:-${AZURE_COSMOS_CONNECTION_STRING:-}}}" ]] && return 0
  local rg="${COSMOS_ACCOUNT_RG:-${RESOURCE_GROUP:-}}"
  [[ -z "$rg" ]] && return 0
  echo "[discover] Attempting to auto-discover Cosmos DB account in RG $rg"
  local names
  names=$(az cosmosdb list -g "$rg" --query '[].name' -o tsv 2>/dev/null || true)
  local count; count=$(echo "$names" | grep -c . || true)
  if [[ $count -eq 1 ]]; then
    COSMOS_ACCOUNT_NAME="$names"; export COSMOS_ACCOUNT_NAME
    COSMOS_ACCOUNT_RG="$rg"; export COSMOS_ACCOUNT_RG
    echo "[discover] COSMOS_ACCOUNT_NAME=$COSMOS_ACCOUNT_NAME"
  elif [[ $count -gt 1 ]]; then
    echo "[discover] Multiple Cosmos accounts found; set COSMOS_ACCOUNT_NAME manually:" >&2
    echo "$names" >&2
  else
    echo "[discover] No Cosmos accounts found in $rg" >&2
  fi
}


package_and_deploy() {
  echo "[package] Creating workflow archive"
  local tmp_zip="$(mktemp -u)/workflows.zip"; mkdir -p "$(dirname "$tmp_zip")"; (cd "$workflows_dir" && zip -qr "$tmp_zip" .)
  echo "[deploy] Deploying to $LOGIC_APP_NAME"
  az logicapp deployment source config-zip --name "$LOGIC_APP_NAME" --resource-group "$LOGIC_APP_RESOURCE_GROUP" --src "$tmp_zip"
}

maybe_temp_network_open() {
  [[ -n "${TEMP_ALLOW_IP:-}" ]] || return 0
  # Determine kind to ensure commands appropriate for logic app vs web app
  local kind
  kind=$(az resource show --resource-group "$LOGIC_APP_RESOURCE_GROUP" --resource-type Microsoft.Web/sites --name "$LOGIC_APP_NAME" --query "kind" -o tsv 2>/dev/null || echo "")
  echo "[net] Target site kind='$kind'"
  echo "[net] Temporarily enabling public access & adding rule for $TEMP_ALLOW_IP"
  # Some kinds (workflowapp) may reject az webapp update message; attempt resource-level update then ignore failures
  az resource update --resource-group "$LOGIC_APP_RESOURCE_GROUP" --resource-type Microsoft.Web/sites --name "$LOGIC_APP_NAME" --set properties.publicNetworkAccess=Enabled 1>/dev/null 2>&1 || \
    az webapp update --resource-group "$LOGIC_APP_RESOURCE_GROUP" --name "$LOGIC_APP_NAME" --set publicNetworkAccess=Enabled 1>/dev/null 2>&1 || true
  az webapp config access-restriction set --resource-group "$LOGIC_APP_RESOURCE_GROUP" --name "$LOGIC_APP_NAME" --use-same-restrictions-for-scm-site true 1>/dev/null 2>&1 || true
  local rule_name="temp-allow-${TEMP_ALLOW_IP//./-}"; local priority="${ACCESS_RULE_PRIORITY:-110}"
  az webapp config access-restriction add --resource-group "$LOGIC_APP_RESOURCE_GROUP" --name "$LOGIC_APP_NAME" --rule-name "$rule_name" --action Allow --ip-address "$TEMP_ALLOW_IP" --priority "$priority" --scm-site false 1>/dev/null 2>&1 || true
  az webapp config access-restriction add --resource-group "$LOGIC_APP_RESOURCE_GROUP" --name "$LOGIC_APP_NAME" --rule-name "$rule_name" --action Allow --ip-address "$TEMP_ALLOW_IP" --priority "$priority" --scm-site true 1>/dev/null 2>&1 || true
}

maybe_temp_network_close() {
  [[ -n "${TEMP_ALLOW_IP:-}" ]] || return 0
  echo "[net] Restoring publicNetworkAccess=Disabled (best-effort)"
  az resource update --resource-group "$LOGIC_APP_RESOURCE_GROUP" --resource-type Microsoft.Web/sites --name "$LOGIC_APP_NAME" --set properties.publicNetworkAccess=Disabled 1>/dev/null 2>&1 || \
    az webapp update --resource-group "$LOGIC_APP_RESOURCE_GROUP" --name "$LOGIC_APP_NAME" --set publicNetworkAccess=Disabled 1>/dev/null 2>&1 || true
  local state
  state=$(az webapp show --resource-group "$LOGIC_APP_RESOURCE_GROUP" --name "$LOGIC_APP_NAME" --query "publicNetworkAccess" -o tsv 2>/dev/null || echo "Unknown")
  echo "[net] Logic App publicNetworkAccess=$state"
}

main() {
  echo "[start] Deploy Logic App workflows"
  load_env
  require_env SUBSCRIPTION_ID; require_env LOCATION; require_env LOGIC_APP_NAME
  LOGIC_APP_RESOURCE_GROUP="${LOGIC_APP_RESOURCE_GROUP:-${RESOURCE_GROUP:-}}"; FUNCTION_RESOURCE_GROUP="${FUNCTION_RESOURCE_GROUP:-${RESOURCE_GROUP:-}}"
  require_env LOGIC_APP_RESOURCE_GROUP; require_env FUNCTION_APP_NAME; require_env FUNCTION_RESOURCE_GROUP
  fetch_function_metadata; fetch_sharepoint_connection_runtime_url || true
  # Discover service endpoints / secrets before compiling app settings list
  auto_discover_cosmos_account || true
  discover_openai_endpoint
  discover_search_endpoint
  discover_cosmos_connection_string
  discover_blob_endpoint
  # Storage connection string logic removed (endpoint only)

  echo "[appsettings] Upserting required app settings"
  # Build list of key=value arguments (portable: avoids associative arrays which may not be supported in minimal bash variants)
  app_args=()
  expected_keys=()
  add_app_setting() { # key value
    local k="$1" v="$2"
    [[ -z "$k" || -z "$v" ]] && return 0
    app_args+=("$k=$v")
    expected_keys+=("$k")
  }
  for v in SUBSCRIPTION_ID LOCATION FUNCTION_RESOURCE_GROUP SHAREPOINT_CONNECTION_RG FUNCTION_APP_NAME SHAREPOINT_CONNECTION_NAME FUNCTION_APP_DEFAULT_HOSTNAME SHAREPOINT_CONNECTION_RUNTIME_URL azureFunctionOperation_functionAppKey AzureBlob_blobStorageEndpoint AzureCosmosDB_connectionString openai_openAIEndpoint azureaisearch_searchServiceEndpoint; do
    [[ -n "${!v:-}" ]] && add_app_setting "$v" "${!v}" || true
  done
  if [[ -n "${FUNCTION_APP_DEFAULT_HOSTNAME:-}" ]]; then
    add_app_setting FUNCTION_APP_HOSTNAME_PROCESS_DOCUMENT "https://${FUNCTION_APP_DEFAULT_HOSTNAME}/api/process-document"
    add_app_setting FUNCTION_APP_HOSTNAME_GENERATE_DOCUMENT_ID "https://${FUNCTION_APP_DEFAULT_HOSTNAME}/api/generate-document-id"
    add_app_setting FUNCTION_APP_HOSTNAME_INDEX_DOCUMENTS "https://${FUNCTION_APP_DEFAULT_HOSTNAME}/api/index-documents"
  fi

  echo "[appsettings] Candidate keys to upsert (${#expected_keys[@]}):";
  # For sensitive keys, do not output the value at all; for non-sensitive keys, show value.
  for k in "${expected_keys[@]}"; do
    for pair in "${app_args[@]}"; do
      [[ "$pair" == "$k="* ]] || continue
      val="${pair#*=}"
      case "$k" in
        *connectionString*|*ConnectionString*|*functionAppKey*|*FunctionAppKey*|*hostKey*|*HostKey*|*KEY*|*Key*)
          echo "  - $k (sensitive)"
          ;;
        *)
          echo "  - $k=$val"
          ;;
      esac
      break
    done
  done | sort

  if (( ${#expected_keys[@]} == 0 )); then
    echo "[appsettings][warn] No app settings collected (unexpected)." >&2
  else
    if ! az webapp config appsettings set --resource-group "$LOGIC_APP_RESOURCE_GROUP" --name "$LOGIC_APP_NAME" --settings "${app_args[@]}" 1>/dev/null; then
      echo "[error] Failed to set app settings (az webapp config appsettings set)" >&2
      exit 1
    fi
    echo "[appsettings] Applied settings. Verifying..."
    # Fetch current settings and report missing ones
    current_json=$(az webapp config appsettings list --resource-group "$LOGIC_APP_RESOURCE_GROUP" --name "$LOGIC_APP_NAME" -o json || echo '[]')
    missing=()
    for k in "${expected_keys[@]}"; do
      if ! echo "$current_json" | grep -q '"name": *"'$k'"'; then
        missing+=("$k")
      fi
    done
    if (( ${#missing[@]} > 0 )); then
      echo "[appsettings][warn] The following keys were not found after apply:" >&2
      printf '  - %s\n' "${missing[@]}" >&2
      echo "[appsettings][hint] Possible causes: RBAC permissions, slot mismatch, transient API failure, incorrect LOGIC_APP_NAME, or resource still provisioning." >&2
    else
      echo "[appsettings] Verification successful (all keys present)."
    fi
  fi

  maybe_temp_network_open
  package_and_deploy
  maybe_temp_network_close
  echo "[done] Logic App workflows deployment finished"
}

main "$@"
