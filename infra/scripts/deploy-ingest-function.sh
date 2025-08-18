#!/usr/bin/env bash
# Deploy the ingest Function App using Functions Core Tools.
# Loads .env from this folder, optionally enables temporary public access, then publishes with --build remote.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
func_dir="$repo_root/../ingest-function"

# Load local .env (does not overwrite variables already set in the environment)
env_file="$script_dir/.env"
if [[ -f "$env_file" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" == *" #"* ]]; then
      line="${line%% #*}"
    fi
    line="${line#${line%%[![:space:]]*}}"; line="${line%${line##*[![:space:]]}}"
    [[ "$line" != *"="* ]] && continue
    key="${line%%=*}"; val="${line#*=}"
    key="${key#${key%%[![:space:]]*}}"; key="${key%${key##*[![:space:]]}}"
    val="${val#${val%%[![:space:]]*}}"; val="${val%${val##*[![:space:]]}}"
    if [[ ${#val} -ge 2 && ( ( "${val:0:1}" == '"' && "${val: -1}" == '"' ) || ( "${val:0:1}" == "'" && "${val: -1}" == "'" ) ) ]]; then
      val="${val:1:${#val}-2}"
    else
      val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
    fi
    if [[ -z "${!key:-}" ]]; then export "$key=$val"; fi
  done < "$env_file"
fi

# Dependencies
command -v az >/dev/null || { echo "Azure CLI (az) is required" >&2; exit 1; }
command -v func >/dev/null || { echo "Functions Core Tools (func) is required" >&2; exit 1; }

# Required inputs
FUNCTION_RESOURCE_GROUP="${FUNCTION_RESOURCE_GROUP:-${RESOURCE_GROUP:-}}"
: "${FUNCTION_APP_NAME:?Set FUNCTION_APP_NAME (target Function App name)}"
: "${FUNCTION_RESOURCE_GROUP:?Set FUNCTION_RESOURCE_GROUP or RESOURCE_GROUP (resource group of the Function App)}"

# 1) If TEMP_ALLOW_IP is set, enable public access then allow IP for main + SCM
if [[ -n "${TEMP_ALLOW_IP:-}" ]]; then
  echo "Enabling public network access for Function App '$FUNCTION_APP_NAME'"
  az functionapp update \
    --resource-group "$FUNCTION_RESOURCE_GROUP" \
    --name "$FUNCTION_APP_NAME" \
    --set publicNetworkAccess=Enabled 1>/dev/null || true

  # Ensure scm follows main restrictions
  az webapp config access-restriction set \
    --resource-group "$FUNCTION_RESOURCE_GROUP" \
    --name "$FUNCTION_APP_NAME" \
    --use-same-restrictions-for-scm-site true 1>/dev/null || true

  rule_name="temp-allow-${TEMP_ALLOW_IP//./-}"
  priority="${ACCESS_RULE_PRIORITY:-100}"
  echo "Allowing IP $TEMP_ALLOW_IP for Function App (main + scm) with rule '$rule_name'"
  az webapp config access-restriction add \
    --resource-group "$FUNCTION_RESOURCE_GROUP" \
    --name "$FUNCTION_APP_NAME" \
    --rule-name "$rule_name" \
    --action Allow \
    --ip-address "$TEMP_ALLOW_IP" \
    --priority "$priority" \
    --scm-site false 1>/dev/null
  az webapp config access-restriction add \
    --resource-group "$FUNCTION_RESOURCE_GROUP" \
    --name "$FUNCTION_APP_NAME" \
    --rule-name "$rule_name" \
    --action Allow \
    --ip-address "$TEMP_ALLOW_IP" \
    --priority "$priority" \
    --scm-site true 1>/dev/null || true
fi

publish_args=(--build remote)
if [[ "${PUBLISH_LOCAL_SETTINGS:-false}" =~ ^(?i:1|true|yes|y)$ ]]; then
  publish_args+=(--publish-local-settings)
fi

echo "Publishing function from '$func_dir'"
pushd "$func_dir" >/dev/null
func azure functionapp publish "$FUNCTION_APP_NAME" "${publish_args[@]}"
popd >/dev/null

# 2) Disable public access after successful deployment
echo "Disabling public network access for Function App '$FUNCTION_APP_NAME'"
az functionapp update \
  --resource-group "$FUNCTION_RESOURCE_GROUP" \
  --name "$FUNCTION_APP_NAME" \
  --set publicNetworkAccess=Disabled 1>/dev/null || true

state=$(az functionapp show \
  --resource-group "$FUNCTION_RESOURCE_GROUP" \
  --name "$FUNCTION_APP_NAME" \
  --query "publicNetworkAccess" -o tsv 2>/dev/null || echo "Unknown")
echo "Function App '$FUNCTION_APP_NAME' deployment complete. publicNetworkAccess=$state"
