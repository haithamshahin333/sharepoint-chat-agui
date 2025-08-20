#!/usr/bin/env bash
# Deploy the Next.js web app to Azure App Service (Linux) using remote Oryx build via ZIP deploy.
# - Loads .env from this folder
# - Optionally enables temporary public access and IP allow-listing (main + scm)
# - Adds missing app settings only (does not overwrite existing keys)
# - Zips the frontend/ folder (excluding heavy dev artifacts) and deploys with az webapp deploy
# - Disables public access after deployment and prints final state

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
frontend_dir_default="$repo_root/../frontend"

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

# Required inputs
WEBAPP_RESOURCE_GROUP="${WEBAPP_RESOURCE_GROUP:-${RESOURCE_GROUP:-}}"
: "${WEBAPP_NAME:?Set WEBAPP_NAME (target Web App name)}"
: "${WEBAPP_RESOURCE_GROUP:?Set WEBAPP_RESOURCE_GROUP or RESOURCE_GROUP (resource group of the Web App)}"

# Frontend directory (override with FRONTEND_DIR if needed)
frontend_dir="${FRONTEND_DIR:-$frontend_dir_default}"
if [[ ! -d "$frontend_dir" ]]; then
  echo "Frontend directory not found: $frontend_dir" >&2
  exit 1
fi

# 1) If TEMP_ALLOW_IP is set, enable public access then allow IP for main + SCM
if [[ -n "${TEMP_ALLOW_IP:-}" ]]; then
  echo "Enabling public network access for Web App '$WEBAPP_NAME'"
  az webapp update \
    --resource-group "$WEBAPP_RESOURCE_GROUP" \
    --name "$WEBAPP_NAME" \
    --set publicNetworkAccess=Enabled 1>/dev/null || true

  # Ensure scm follows main restrictions
  az webapp config access-restriction set \
    --resource-group "$WEBAPP_RESOURCE_GROUP" \
    --name "$WEBAPP_NAME" \
    --use-same-restrictions-for-scm-site true 1>/dev/null || true

  rule_name="temp-allow-${TEMP_ALLOW_IP//./-}"
  priority="${ACCESS_RULE_PRIORITY:-100}"
  echo "Ensuring IP $TEMP_ALLOW_IP is allowed for Web App (main + scm) with rule '$rule_name'"

  # Check if main site already has this IP allow rule
  exists_main=$(az webapp config access-restriction show \
    --resource-group "$WEBAPP_RESOURCE_GROUP" \
    --name "$WEBAPP_NAME" \
    --query "ipSecurityRestrictions[?ipAddress=='${TEMP_ALLOW_IP}/32' && action=='Allow'] | length(@)" -o tsv 2>/dev/null || echo "0")
  if [[ "$exists_main" == "0" ]]; then
    az webapp config access-restriction add \
      --resource-group "$WEBAPP_RESOURCE_GROUP" \
      --name "$WEBAPP_NAME" \
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
    --resource-group "$WEBAPP_RESOURCE_GROUP" \
    --name "$WEBAPP_NAME" \
    --query "scmIpSecurityRestrictions[?ipAddress=='${TEMP_ALLOW_IP}/32' && action=='Allow'] | length(@)" -o tsv 2>/dev/null || echo "0")
  if [[ "$exists_scm" == "0" ]]; then
    az webapp config access-restriction add \
      --resource-group "$WEBAPP_RESOURCE_GROUP" \
      --name "$WEBAPP_NAME" \
      --rule-name "$rule_name" \
      --action Allow \
      --ip-address "$TEMP_ALLOW_IP" \
      --priority "$priority" \
      --scm-site true 1>/dev/null || true
  else
    echo "- SCM site already has allow rule for ${TEMP_ALLOW_IP}/32; skipping add"
  fi
fi

# 2) Add missing app settings only (do not overwrite existing)
echo "Inspecting existing app settings to add missing keys only"
existing_keys="$(az webapp config appsettings list \
  --resource-group "$WEBAPP_RESOURCE_GROUP" \
  --name "$WEBAPP_NAME" \
  --query "[].name" -o tsv || echo "")"

to_set=()
# If an env var provides a value, update the setting; otherwise only add if missing is acceptable.
add_or_update_setting() {
  local key="$1"; local val="$2"
  if [[ -n "$val" ]]; then
    # Update or add with the provided value
    to_set+=("$key=$val")
  else
    # No value provided in env; keep existing if present, or skip
    if ! echo "$existing_keys" | grep -Fxq "$key"; then
      echo "- $key missing and no value provided; skipping"
    else
      echo "- Preserve existing $key (no override provided)"
    fi
  fi
}

# Desired settings (values come from environment / .env defaults)
add_or_update_setting "SCM_DO_BUILD_DURING_DEPLOYMENT" "${SCM_DO_BUILD_DURING_DEPLOYMENT:-}"
add_or_update_setting "ENABLE_ORYX_BUILD" "${ENABLE_ORYX_BUILD:-}"
add_or_update_setting "NEXT_PUBLIC_MSAL_CLIENT_ID" "${NEXT_PUBLIC_MSAL_CLIENT_ID:-}"
add_or_update_setting "NEXT_PUBLIC_MSAL_TENANT_ID" "${NEXT_PUBLIC_MSAL_TENANT_ID:-}"
add_or_update_setting "NEXT_PUBLIC_API_SCOPE" "${NEXT_PUBLIC_API_SCOPE:-}"
add_or_update_setting "PYDANTIC_AGENT_URL" "${PYDANTIC_AGENT_URL:-}"
add_or_update_setting "NEXT_PUBLIC_SEARCH_CATEGORIES" "${NEXT_PUBLIC_SEARCH_CATEGORIES:-}"
add_or_update_setting "NEXT_PUBLIC_DEFAULT_CATEGORY" "${NEXT_PUBLIC_DEFAULT_CATEGORY:-}"
add_or_update_setting "COPILOTKIT_TELEMETRY_DISABLED" "${COPILOTKIT_TELEMETRY_DISABLED:-}"
add_or_update_setting "NEXT_TELEMETRY_DISABLED" "${NEXT_TELEMETRY_DISABLED:-}"
add_or_update_setting "POST_BUILD_COMMAND" "${POST_BUILD_COMMAND:-}"

if (( ${#to_set[@]} > 0 )); then
  echo "Adding missing app settings: ${to_set[*]}"
  az webapp config appsettings set \
    --resource-group "$WEBAPP_RESOURCE_GROUP" \
    --name "$WEBAPP_NAME" \
    --settings "${to_set[@]}" 1>/dev/null
else
  echo "No new app settings to add."
fi

# Warn if SCM_DO_BUILD_DURING_DEPLOYMENT exists but may be false (left unchanged by policy)
current_scm_build=$(az webapp config appsettings list \
  --resource-group "$WEBAPP_RESOURCE_GROUP" \
  --name "$WEBAPP_NAME" \
  --query "[?name=='SCM_DO_BUILD_DURING_DEPLOYMENT'].value | [0]" -o tsv 2>/dev/null || echo "")
if [[ -n "$current_scm_build" && "$current_scm_build" != "true" && "$current_scm_build" != "1" ]]; then
  echo "Note: SCM_DO_BUILD_DURING_DEPLOYMENT is set to '$current_scm_build' and was not changed. Remote build may be skipped."
fi

# 3) Create ZIP of frontend (exclude heavy dev artifacts)
echo "Creating deployment ZIP from: $frontend_dir"
tmpdir="$(mktemp -d)"
zip_path="$tmpdir/webapp.zip"
pushd "$frontend_dir" >/dev/null
zip -r "$zip_path" . \
  -x "node_modules/*" \
  -x ".next/*" \
  -x ".git/*" \
  -x ".vscode/*" \
  -x ".env" \
  -x ".env.*" \
  -x ".env.local" \
  -x "*/.env" \
  -x "*/.env.*" \
  -x "*/.env.local" 1>/dev/null
popd >/dev/null

# 4) Deploy ZIP (Oryx remote build will run if SCM_DO_BUILD_DURING_DEPLOYMENT=true)
echo "Deploying ZIP to Web App '$WEBAPP_NAME'"
az webapp deploy \
  --resource-group "$WEBAPP_RESOURCE_GROUP" \
  --name "$WEBAPP_NAME" \
  --src-path "$zip_path" \
  --type zip 1>/dev/null

rm -f "$zip_path"; rmdir "$tmpdir" || true

# 5) Disable public access after successful deployment (non-fatal if this step hiccups)
set +e
echo "Disabling public network access for Web App '$WEBAPP_NAME'"
az webapp update --resource-group "$WEBAPP_RESOURCE_GROUP" --name "$WEBAPP_NAME" --set publicNetworkAccess=Disabled 1>/dev/null || true

state=$(az webapp show --resource-group "$WEBAPP_RESOURCE_GROUP" --name "$WEBAPP_NAME" --query "publicNetworkAccess" -o tsv 2>/dev/null)
if [[ -z "$state" ]]; then state="Unknown"; fi
echo "Web App '$WEBAPP_NAME' deployment complete. publicNetworkAccess=$state"
set -e
