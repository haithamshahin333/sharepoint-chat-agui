#!/usr/bin/env bash
# Deploy the FastAPI backend to Azure App Service (Linux) using remote Oryx build via ZIP deploy.
# - Loads .env from this folder
# - Optionally enables temporary public access and IP allow-listing (main + scm)
# - Adds/updates app settings when values are provided (preserves existing otherwise)
# - Zips the pydantic-agent/ folder (excluding heavy dev artifacts) and deploys with az webapp deploy
# - Sets a sane startup command for uvicorn (override with BACKEND_STARTUP_COMMAND)
# - Disables public access after deployment and prints final state

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
backend_dir_default="$repo_root/../pydantic-agent"

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

# Optional: set subscription from env
if [[ -n "${AZ_SUBSCRIPTION_ID:-}" ]]; then
  az account set --subscription "$AZ_SUBSCRIPTION_ID" 1>/dev/null
fi

# Dependencies
command -v az >/dev/null || { echo "Azure CLI (az) is required" >&2; exit 1; }
command -v zip >/dev/null || { echo "zip is required (sudo apt-get install zip)" >&2; exit 1; }

# Required inputs (prefer BACKEND_*; fallback to WEBAPP_*)
TARGET_WEBAPP_NAME="${BACKEND_WEBAPP_NAME:-${WEBAPP_NAME:-}}"
TARGET_WEBAPP_RG="${BACKEND_WEBAPP_RESOURCE_GROUP:-${WEBAPP_RESOURCE_GROUP:-${RESOURCE_GROUP:-}}}"

: "${TARGET_WEBAPP_NAME:?Set BACKEND_WEBAPP_NAME or WEBAPP_NAME (target Web App name)}"
: "${TARGET_WEBAPP_RG:?Set BACKEND_WEBAPP_RESOURCE_GROUP or WEBAPP_RESOURCE_GROUP (resource group of the Web App)}"

# Backend directory (override with BACKEND_DIR if needed)
backend_dir="${BACKEND_DIR:-$backend_dir_default}"
if [[ ! -d "$backend_dir" ]]; then
  echo "Backend directory not found: $backend_dir" >&2
  exit 1
fi

# 1) If TEMP_ALLOW_IP is set, enable public access then allow IP for main + SCM
if [[ -n "${TEMP_ALLOW_IP:-}" ]]; then
  echo "Enabling public network access for Web App '$TARGET_WEBAPP_NAME'"
  az webapp update \
    --resource-group "$TARGET_WEBAPP_RG" \
    --name "$TARGET_WEBAPP_NAME" \
    --set publicNetworkAccess=Enabled 1>/dev/null || true

  # Ensure scm follows main restrictions
  az webapp config access-restriction set \
    --resource-group "$TARGET_WEBAPP_RG" \
    --name "$TARGET_WEBAPP_NAME" \
    --use-same-restrictions-for-scm-site true 1>/dev/null || true

  rule_name="temp-allow-${TEMP_ALLOW_IP//./-}"
  priority="${ACCESS_RULE_PRIORITY:-100}"
  echo "Ensuring IP $TEMP_ALLOW_IP is allowed for Web App (main + scm) with rule '$rule_name'"

  # Check if main site already has this IP allow rule
  exists_main=$(az webapp config access-restriction show \
    --resource-group "$TARGET_WEBAPP_RG" \
    --name "$TARGET_WEBAPP_NAME" \
    --query "ipSecurityRestrictions[?ipAddress=='${TEMP_ALLOW_IP}/32' && action=='Allow'] | length(@)" -o tsv 2>/dev/null || echo "0")
  if [[ "$exists_main" == "0" ]]; then
    az webapp config access-restriction add \
      --resource-group "$TARGET_WEBAPP_RG" \
      --name "$TARGET_WEBAPP_NAME" \
      --rule-name "$rule_name" \
      --action Allow \
      --ip-address "$TEMP_ALLOW_IP" \
      --priority "$priority" \
      --scm-site false 1>/dev/null || true
  else
    echo "- Main site already has allow rule for ${TEMP_ALLOW_IP}/32; skipping add"
  fi

  # Check if SCM site already has this IP allow rule (when not mirroring)
  exists_scm=$(az webapp config access-restriction show \
    --resource-group "$TARGET_WEBAPP_RG" \
    --name "$TARGET_WEBAPP_NAME" \
    --query "scmIpSecurityRestrictions[?ipAddress=='${TEMP_ALLOW_IP}/32' && action=='Allow'] | length(@)" -o tsv 2>/dev/null || echo "0")
  if [[ "$exists_scm" == "0" ]]; then
    az webapp config access-restriction add \
      --resource-group "$TARGET_WEBAPP_RG" \
      --name "$TARGET_WEBAPP_NAME" \
      --rule-name "$rule_name" \
      --action Allow \
      --ip-address "$TEMP_ALLOW_IP" \
      --priority "$priority" \
      --scm-site true 1>/dev/null || true
  else
    echo "- SCM site already has allow rule for ${TEMP_ALLOW_IP}/32; skipping add"
  fi
fi

# 2) Add/update app settings when values provided (preserve existing otherwise)
echo "Inspecting existing app settings and preparing updates"
existing_keys="$(az webapp config appsettings list \
  --resource-group "$TARGET_WEBAPP_RG" \
  --name "$TARGET_WEBAPP_NAME" \
  --query "[].name" -o tsv || echo "")"

to_set=()
add_or_update_setting() {
  local key="$1"; local val="${2:-}"
  if [[ -n "$val" ]]; then
    to_set+=("$key=$val")
  else
    if echo "$existing_keys" | grep -Fxq "$key"; then
      echo "- Preserve existing $key (no override provided)"
    else
      echo "- $key missing and no value provided; skipping"
    fi
  fi
}

# Common Oryx flags (optional)
add_or_update_setting "SCM_DO_BUILD_DURING_DEPLOYMENT" "${SCM_DO_BUILD_DURING_DEPLOYMENT:-}"
add_or_update_setting "ENABLE_ORYX_BUILD" "${ENABLE_ORYX_BUILD:-}"
# Python version hint (optional, e.g., 3.12)
add_or_update_setting "PYTHON_VERSION" "${PYTHON_VERSION:-}"

# Backend app settings
add_or_update_setting "AZURE_OPENAI_ENDPOINT" "${AZURE_OPENAI_ENDPOINT:-}"
add_or_update_setting "AZURE_OPENAI_API_VERSION" "${AZURE_OPENAI_API_VERSION:-}"
add_or_update_setting "AZURE_OPENAI_DEPLOYMENT_NAME" "${AZURE_OPENAI_DEPLOYMENT_NAME:-}"
add_or_update_setting "AZURE_STORAGE_ACCOUNT_NAME" "${AZURE_STORAGE_ACCOUNT_NAME:-}"
add_or_update_setting "AZURE_SEARCH_ENDPOINT" "${AZURE_SEARCH_ENDPOINT:-}"
add_or_update_setting "AZURE_SEARCH_INDEX_NAME" "${AZURE_SEARCH_INDEX_NAME:-}"
add_or_update_setting "AZURE_SEARCH_SEMANTIC_CONFIG" "${AZURE_SEARCH_SEMANTIC_CONFIG:-}"
add_or_update_setting "DEFAULT_CATEGORY_VALUE" "${DEFAULT_CATEGORY_VALUE:-}"
add_or_update_setting "API_HOSTNAME" "${API_HOSTNAME:-}"
add_or_update_setting "OTEL_EXPORTER_OTLP_ENDPOINT" "${OTEL_EXPORTER_OTLP_ENDPOINT:-}"

if (( ${#to_set[@]} > 0 )); then
  echo "Applying app settings updates: ${to_set[*]}"
  az webapp config appsettings set \
    --resource-group "$TARGET_WEBAPP_RG" \
    --name "$TARGET_WEBAPP_NAME" \
    --settings "${to_set[@]}" 1>/dev/null
else
  echo "No app settings to change."
fi

# 3) Set Startup Command (uvicorn) if provided or default
startup_cmd="${BACKEND_STARTUP_COMMAND:-}"
if [[ -z "$startup_cmd" ]]; then
  startup_cmd="python -m uvicorn main:app --host 0.0.0.0 --port 8000"
fi
echo "Setting startup command: $startup_cmd"
az webapp config set \
  --resource-group "$TARGET_WEBAPP_RG" \
  --name "$TARGET_WEBAPP_NAME" \
  --startup-file "$startup_cmd" 1>/dev/null

# 4) Create ZIP of backend (exclude heavy dev artifacts and secrets)
echo "Creating deployment ZIP from: $backend_dir"
_tmpdir="$(mktemp -d)"
zip_path="$_tmpdir/backend.zip"
pushd "$backend_dir" >/dev/null
zip -r "$zip_path" . \
  -x "*.pyc" \
  -x "__pycache__/*" \
  -x ".git/*" \
  -x ".vscode/*" \
  -x "venv/*" \
  -x ".venv/*" \
  -x ".env" \
  -x ".env.*" \
  -x ".env.local" \
  -x "*/.env" \
  -x "*/.env.*" \
  -x "*/.env.local" 1>/dev/null
popd >/dev/null

# 5) Deploy ZIP (Oryx remote build will run if SCM_DO_BUILD_DURING_DEPLOYMENT=true)
echo "Deploying ZIP to Web App '$TARGET_WEBAPP_NAME'"
az webapp deploy \
  --resource-group "$TARGET_WEBAPP_RG" \
  --name "$TARGET_WEBAPP_NAME" \
  --src-path "$zip_path" \
  --type zip 1>/dev/null

rm -f "$zip_path"; rmdir "$_tmpdir" || true

# 6) Disable public access after successful deployment (non-fatal if this step hiccups)
set +e
echo "Disabling public network access for Web App '$TARGET_WEBAPP_NAME'"
az webapp update --resource-group "$TARGET_WEBAPP_RG" --name "$TARGET_WEBAPP_NAME" --set publicNetworkAccess=Disabled 1>/dev/null || true

state=$(az webapp show --resource-group "$TARGET_WEBAPP_RG" --name "$TARGET_WEBAPP_NAME" --query "publicNetworkAccess" -o tsv 2>/dev/null)
if [[ -z "$state" ]]; then state="Unknown"; fi
echo "Web App '$TARGET_WEBAPP_NAME' deployment complete. publicNetworkAccess=$state"
set -e

# References:
# - az webapp deploy: https://learn.microsoft.com/azure/app-service/deploy-zip?tabs=cli
# - Access restrictions: https://learn.microsoft.com/azure/app-service/app-service-ip-restrictions
# - Startup command: https://learn.microsoft.com/azure/app-service/configure-language-python#customize-startup-command
# - Oryx build overview: https://github.com/microsoft/Oryx
