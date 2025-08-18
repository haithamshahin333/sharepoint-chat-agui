#!/usr/bin/env bash
# Orchestrated post-deploy script: search index -> function app -> logic app workflows.
# Skips web apps per current requirement.
# Optional skip flags (set to any non-empty value): SKIP_SEARCH_INDEX, SKIP_FUNCTION_DEPLOY, SKIP_LOGIC_WORKFLOWS
# Usage: ./post-deploy.sh
# Uses unified RESOURCE_GROUP from .env; individual scripts allow overrides.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[orchestrator] Loading environment (.env) once"
env_file="$script_dir/.env"
if [[ -f "$env_file" ]]; then
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    raw="${raw%$'\r'}"
    [[ -z "$raw" || "$raw" =~ ^[[:space:]]*# ]] && continue
    # Strip inline comment starting with space-hash (not inside quotes heuristic)
    if [[ "$raw" == *" #"* ]]; then raw="${raw%% #*}"; fi
    # Trim
    line="${raw#${raw%%[![:space:]]*}}"; line="${line%${line##*[![:space:]]}}"
    [[ -z "$line" ]] && continue
    [[ "$line" != *"="* ]] && continue
    key="${line%%=*}"; val="${line#*=}"
    key="${key#${key%%[![:space:]]*}}"; key="${key%${key##*[![:space:]]}}"
    # Detect obvious unbalanced quotes (single or double) -> warn & skip
    if [[ $(grep -o '"' <<<"$val" | wc -l) -eq 1 ]] || [[ $(grep -o "'" <<<"$val" | wc -l) -eq 1 ]]; then
      echo "[env-warn] Skipping line with unmatched quote: $key" >&2
      continue
    fi
    # Remove one layer of matching surrounding quotes
    if [[ ${#val} -ge 2 && ( ( ${val:0:1} == '"' && ${val: -1} == '"' ) || ( ${val:0:1} == "'" && ${val: -1} == "'" ) ) ]]; then
      val="${val:1:${#val}-2}"
    fi
    # Export only if not already in env
    if [[ -z "${!key:-}" ]]; then
      export "$key=$val"
    fi
  done < "$env_file"
else
  echo "[warn] No .env file found at $env_file" >&2
fi

start_ts=$(date +%s)

# ---------------------------------------------
# Discovery helpers (require az CLI)
# ---------------------------------------------
ensure_az() { command -v az >/dev/null || { echo "[error] Azure CLI (az) required" >&2; exit 1; }; }

discover_search_service() {
  [[ -n "${SEARCH_SERVICE:-}" ]] && return
  [[ -z "${RESOURCE_GROUP:-}" ]] && return
  echo "[discover] Searching for Azure AI Search services in RG $RESOURCE_GROUP"
  local names json
  json=$(az resource list -g "$RESOURCE_GROUP" --resource-type Microsoft.Search/searchServices -o json 2>/dev/null || echo '[]')
  names=$(echo "$json" | jq -r '.[].name')
  local count
  count=$(echo "$names" | grep -c . || true)
  if [[ $count -eq 1 ]]; then
    SEARCH_SERVICE="$names"; export SEARCH_SERVICE
    echo "[discover] SEARCH_SERVICE=$SEARCH_SERVICE"
  elif [[ $count -gt 1 ]]; then
    echo "[discover] Multiple search services found; set SEARCH_SERVICE manually:" >&2
    echo "$names" >&2
  else
    echo "[discover] No search service found in $RESOURCE_GROUP" >&2
  fi
}

discover_function_app() {
  [[ -n "${FUNCTION_APP_NAME:-}" ]] && return
  [[ -z "${RESOURCE_GROUP:-}" ]] && return
  echo "[discover] Searching for Function Apps in RG $RESOURCE_GROUP"
  local names json
  json=$(az resource list -g "$RESOURCE_GROUP" --resource-type Microsoft.Web/sites --query "[?kind && contains(kind, 'functionapp') && !contains(kind,'workflowapp')]" -o json 2>/dev/null || echo '[]')
  names=$(echo "$json" | jq -r '.[].name')
  local count; count=$(echo "$names" | grep -c . || true)
  if [[ $count -eq 1 ]]; then
    FUNCTION_APP_NAME="$names"; export FUNCTION_APP_NAME
    echo "[discover] FUNCTION_APP_NAME=$FUNCTION_APP_NAME"
  elif [[ $count -gt 1 ]]; then
    echo "[discover] Multiple function apps found; set FUNCTION_APP_NAME manually:" >&2
    echo "$names" >&2
  else
    echo "[discover] No function apps located" >&2
  fi
}

discover_logic_app() {
  [[ -n "${LOGIC_APP_NAME:-}" ]] && return
  [[ -z "${RESOURCE_GROUP:-}" ]] && return
  echo "[discover] Searching for Logic App Standard (workflowapp) sites in RG $RESOURCE_GROUP"
  local names json
  json=$(az resource list -g "$RESOURCE_GROUP" --resource-type Microsoft.Web/sites --query "[?kind && contains(kind,'workflowapp')]" -o json 2>/dev/null || echo '[]')
  names=$(echo "$json" | jq -r '.[].name')
  local count; count=$(echo "$names" | grep -c . || true)
  if [[ $count -eq 1 ]]; then
    LOGIC_APP_NAME="$names"; export LOGIC_APP_NAME
    echo "[discover] LOGIC_APP_NAME=$LOGIC_APP_NAME"
  elif [[ $count -gt 1 ]]; then
    echo "[discover] Multiple logic apps found; set LOGIC_APP_NAME manually:" >&2
    echo "$names" >&2
  else
    echo "[discover] No logic apps located" >&2
  fi
}

discover_sharepoint_connection() {
  [[ -n "${SHAREPOINT_CONNECTION_NAME:-}" ]] && return
  [[ -z "${RESOURCE_GROUP:-}" ]] && return
  echo "[discover] Searching for SharePoint connection in RG $RESOURCE_GROUP"
  local names json
  json=$(az resource list -g "$RESOURCE_GROUP" --resource-type Microsoft.Web/connections --query "[?contains(name, 'sharepoint') || contains(properties.api.name, 'sharepointonline')]" -o json 2>/dev/null || echo '[]')
  names=$(echo "$json" | jq -r '.[].name')
  local count; count=$(echo "$names" | grep -c . || true)
  if [[ $count -eq 1 ]]; then
    SHAREPOINT_CONNECTION_NAME="$names"; export SHAREPOINT_CONNECTION_NAME
    SHAREPOINT_CONNECTION_RG="${SHAREPOINT_CONNECTION_RG:-$RESOURCE_GROUP}"; export SHAREPOINT_CONNECTION_RG
    echo "[discover] SHAREPOINT_CONNECTION_NAME=$SHAREPOINT_CONNECTION_NAME"
  elif [[ $count -gt 1 ]]; then
    echo "[discover] Multiple SharePoint connections found; set SHAREPOINT_CONNECTION_NAME manually:" >&2
    echo "$names" >&2
  else
    echo "[discover] No SharePoint connections located" >&2
  fi
}

print_summary() {
  echo "[summary] Using values:"
  printf '  RESOURCE_GROUP=%s\n' "${RESOURCE_GROUP:-}" 
  printf '  SEARCH_SERVICE=%s\n' "${SEARCH_SERVICE:-<unset>}" 
  printf '  FUNCTION_APP_NAME=%s\n' "${FUNCTION_APP_NAME:-<unset>}" 
  printf '  LOGIC_APP_NAME=%s\n' "${LOGIC_APP_NAME:-<unset>}" 
  printf '  SHAREPOINT_CONNECTION_NAME=%s\n' "${SHAREPOINT_CONNECTION_NAME:-<unset>}" 
  printf '  SEARCH_INDEX_NAME=%s\n' "${SEARCH_INDEX_NAME:-<unset>}"
}

run_step() {
  local name="$1"; shift
  local cmd=("$@")
  echo "[step:$name] START $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if "${cmd[@]}"; then
    echo "[step:$name] OK"
  else
    echo "[step:$name] FAILED" >&2
    exit 1
  fi
}

# Auto-discover missing resource names (best-effort)
ensure_az
discover_search_service || true
discover_function_app || true
discover_logic_app || true
discover_sharepoint_connection || true
print_summary

# 1) Create / update search index
if [[ -n "${SKIP_SEARCH_INDEX:-}" ]]; then
  echo "[skip] search index step skipped (SKIP_SEARCH_INDEX set)"
else
  run_step search-index bash "$script_dir/create-search-index.sh"
fi

# 2) Deploy Function App
if [[ -n "${SKIP_FUNCTION_DEPLOY:-}" ]]; then
  echo "[skip] function deploy step skipped (SKIP_FUNCTION_DEPLOY set)"
else
  run_step function-deploy bash "$script_dir/deploy-ingest-function.sh"
fi

# 3) Deploy Logic App workflows
if [[ -n "${SKIP_LOGIC_WORKFLOWS:-}" ]]; then
  echo "[skip] logic workflows step skipped (SKIP_LOGIC_WORKFLOWS set)"
else
  # Explicitly inject function context to avoid reliance on sub-shell inheriting exports only
  run_step logic-workflows env \
    FUNCTION_APP_NAME="${FUNCTION_APP_NAME:-}" \
    FUNCTION_RESOURCE_GROUP="${FUNCTION_RESOURCE_GROUP:-${RESOURCE_GROUP:-}}" \
    SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-}" \
    LOCATION="${LOCATION:-}" \
    LOGIC_APP_NAME="${LOGIC_APP_NAME:-}" \
    LOGIC_APP_RESOURCE_GROUP="${LOGIC_APP_RESOURCE_GROUP:-${RESOURCE_GROUP:-}}" \
    SHAREPOINT_CONNECTION_NAME="${SHAREPOINT_CONNECTION_NAME:-}" \
    SHAREPOINT_CONNECTION_RG="${SHAREPOINT_CONNECTION_RG:-${RESOURCE_GROUP:-}}" \
    RESOURCE_GROUP="${RESOURCE_GROUP:-}" \
    bash "$script_dir/deploy-logic-workflows.sh"
fi

end_ts=$(date +%s)
echo "[orchestrator] All requested steps completed in $((end_ts-start_ts))s"
