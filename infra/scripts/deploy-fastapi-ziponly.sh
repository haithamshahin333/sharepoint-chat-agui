#!/usr/bin/env bash
# Minimal FastAPI ZIP and deploy script for Azure App Service
#
# Required environment variables:
#   BACKEND_WEBAPP_NAME              # Target Azure Web App name (required)
#   BACKEND_WEBAPP_RESOURCE_GROUP    # Resource group of the Web App (required)
#   BACKEND_DIR                      # Path to FastAPI backend directory (optional, defaults to ../pydantic-agent)
#
# Usage:
#   export BACKEND_WEBAPP_NAME=your-backend-app
#   export BACKEND_WEBAPP_RESOURCE_GROUP=your-rg
#   export BACKEND_DIR=../pydantic-agent   # (optional)
#   ./deploy-fastapi-ziponly.sh

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
backend_dir_default="$repo_root/../pydantic-agent"
backend_dir="${BACKEND_DIR:-$backend_dir_default}"

if [[ ! -d "$backend_dir" ]]; then
  echo "Backend directory not found: $backend_dir" >&2
  exit 1
fi

: "${BACKEND_WEBAPP_NAME:?Set BACKEND_WEBAPP_NAME (target Web App name)}"
: "${BACKEND_WEBAPP_RESOURCE_GROUP:?Set BACKEND_WEBAPP_RESOURCE_GROUP (resource group of the Web App)}"

# Create ZIP of backend (exclude dev artifacts)
echo "Creating deployment ZIP from: $backend_dir"
tmpdir="$(mktemp -d)"
zip_path="$tmpdir/backend.zip"
pushd "$backend_dir" >/dev/null
zip -r "$zip_path" . \
  -x "__pycache__/*" \
  -x ".git/*" \
  -x ".vscode/*" \
  -x ".env" \
  -x ".env.*" \
  -x ".env.local" \
  -x "*/.env" \
  -x "*/.env.*" \
  -x "*/.env.local" 1>/dev/null
popd >/dev/null

echo "Deploying ZIP to Web App '$BACKEND_WEBAPP_NAME'"
az webapp deploy \
  --resource-group "$BACKEND_WEBAPP_RESOURCE_GROUP" \
  --name "$BACKEND_WEBAPP_NAME" \
  --src-path "$zip_path" \
  --type zip 1>/dev/null

echo "Deployment complete."
rm -f "$zip_path"; rmdir "$tmpdir" || true
