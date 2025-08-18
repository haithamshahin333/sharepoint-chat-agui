#!/usr/bin/env bash
# Create or update an Azure AI Search index from a JSON file with ${...} placeholders.
# Auth: Uses Azure CLI (AAD) with az rest. Requires envsubst for substitution.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

# Optional: load local .env (does not overwrite variables already set in the environment)
env_file="$script_dir/.env"
if [[ -f "$env_file" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    # remove possible Windows CR
    line="${line%$'\r'}"
    # skip full-line comments and empty
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    # strip inline comments starting with ' #' (common style)
    if [[ "$line" == *" #"* ]]; then
      line="${line%% #*}"
    fi
    # basic trim of leading/trailing whitespace
    line="${line#${line%%[![:space:]]*}}"
    line="${line%${line##*[![:space:]]}}"
    # only process KEY=VALUE lines
    [[ "$line" != *"="* ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    # trim whitespace around key and val
    key="${key#${key%%[![:space:]]*}}"; key="${key%${key##*[![:space:]]}}"
    val="${val#${val%%[![:space:]]*}}"; val="${val%${val##*[![:space:]]}}"
    # trim surrounding quotes if any
    if [[ ${#val} -ge 2 && ( ( "${val:0:1}" == '"' && "${val: -1}" == '"' ) || ( "${val:0:1}" == "'" && "${val: -1}" == "'" ) ) ]]; then
      val="${val:1:${#val}-2}"
    else
      val="${val%\"}"; val="${val#\"}"
      val="${val%\'}"; val="${val#\'}"
    fi
    if [[ -z "${!key:-}" ]]; then
      export "$key=$val"
    fi
  done < "$env_file"
fi

# Inputs (env vars)
: "${SEARCH_SERVICE:?Set SEARCH_SERVICE to your search service name (e.g., mysearchsvc)}"
: "${SEARCH_INDEX_NAME:?Set SEARCH_INDEX_NAME to the index name (e.g., chunk)}"
INDEX_FILE="${INDEX_FILE:-$repo_root/search-index.json}"
API_VERSION="${API_VERSION:-2024-07-01}"

# Placeholders present in the JSON
: "${OPENAI_ENDPOINT:?Set OPENAI_ENDPOINT (e.g., https://<aoai-name>.openai.azure.com/)}"
: "${EMBEDDING_DEPLOYMENT_NAME:?Set EMBEDDING_DEPLOYMENT_NAME (embedding deployment id)}"
: "${EMBEDDING_MODEL_NAME:?Set EMBEDDING_MODEL_NAME (model name if required by your config)}"

# Dependencies
if ! command -v az >/dev/null 2>&1; then
  echo "Azure CLI (az) is required on PATH" >&2
  exit 1
fi
if ! command -v envsubst >/dev/null 2>&1; then
  echo "envsubst is required (install gettext-base)." >&2
  exit 1
fi

if [[ ! -f "$INDEX_FILE" ]]; then
  echo "Index JSON not found: $INDEX_FILE" >&2
  exit 1
fi

echo "Creating/updating index '$SEARCH_INDEX_NAME' on service '$SEARCH_SERVICE' from $INDEX_FILE"

tmp_json="$(mktemp)"
trap 'rm -f "$tmp_json"' EXIT

# Only substitute expected variables
VARS='${SEARCH_INDEX_NAME} ${OPENAI_ENDPOINT} ${EMBEDDING_DEPLOYMENT_NAME} ${EMBEDDING_MODEL_NAME}'
envsubst "$VARS" < "$INDEX_FILE" > "$tmp_json"

INDEX_URI="https://${SEARCH_SERVICE}.search.windows.net/indexes/${SEARCH_INDEX_NAME}?api-version=${API_VERSION}"

#############################
# Optional: temp network open
#############################
# To allow running from outside private network, set SEARCH_RESOURCE_GROUP and TEMP_ALLOW_IP.
# This will enable public access with your IP allowed, then disable public access after the index call.
TEMP_ALLOW_IP="${TEMP_ALLOW_IP:-}"
SEARCH_RESOURCE_GROUP="${SEARCH_RESOURCE_GROUP:-${RESOURCE_GROUP:-}}"

orig_pna=""
if [[ -n "$TEMP_ALLOW_IP" && -n "$SEARCH_RESOURCE_GROUP" ]]; then
  echo "Temporarily enabling public access and allowing IP: $TEMP_ALLOW_IP"
  # Capture original public network access state
  orig_pna=$(az search service show \
    --name "$SEARCH_SERVICE" \
    --resource-group "$SEARCH_RESOURCE_GROUP" \
    --query publicNetworkAccess -o tsv || echo "")

  # Merge existing ip-rules with TEMP_ALLOW_IP (semicolon-separated list expected by CLI)
  existing_ips=$(az search service show \
    --name "$SEARCH_SERVICE" \
    --resource-group "$SEARCH_RESOURCE_GROUP" \
    --query "networkRuleSet.ipRules[].value" -o tsv | paste -sd';' - || true)
  if [[ -n "$existing_ips" ]]; then
    merged_ips="$existing_ips;$TEMP_ALLOW_IP"
  else
    merged_ips="$TEMP_ALLOW_IP"
  fi

  az search service update \
    --name "$SEARCH_SERVICE" \
    --resource-group "$SEARCH_RESOURCE_GROUP" \
    --public-network-access enabled \
    --ip-rules "$merged_ips" 1>/dev/null
fi

echo "Using AAD auth via az rest"
az rest \
  --resource https://search.azure.com \
  --method put \
  --uri "$INDEX_URI" \
  --headers "Content-Type=application/json" \
  --body @"$tmp_json" 1>/dev/null

#################################
# Post: disable public access again
#################################
if [[ -n "$TEMP_ALLOW_IP" && -n "$SEARCH_RESOURCE_GROUP" ]]; then
  if [[ "$orig_pna" == "" ]]; then
    echo "Restoring public access: disabling (previous state unknown -> assuming private)"
    az search service update \
      --name "$SEARCH_SERVICE" \
      --resource-group "$SEARCH_RESOURCE_GROUP" \
      --public-network-access disabled 1>/dev/null || true
  elif [[ "$orig_pna" == "enabled" ]]; then
    echo "Restoring public access: leaving enabled (was enabled before)"
  else
    echo "Restoring public access: setting to $orig_pna"
    az search service update \
      --name "$SEARCH_SERVICE" \
      --resource-group "$SEARCH_RESOURCE_GROUP" \
      --public-network-access "$orig_pna" 1>/dev/null || true
  fi
else
  if [[ -n "$TEMP_ALLOW_IP" ]]; then
    echo "[warn] TEMP_ALLOW_IP set but SEARCH_RESOURCE_GROUP/RESOURCE_GROUP missing; cannot open network." >&2
  fi
fi

echo "Index '$SEARCH_INDEX_NAME' created/updated successfully."
