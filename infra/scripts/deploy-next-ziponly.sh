#!/usr/bin/env bash
# Minimal Next.js ZIP and deploy script for Azure App Service
#
# Required environment variables:
#   WEBAPP_NAME              # Target Azure Web App name (required)
#   WEBAPP_RESOURCE_GROUP    # Resource group of the Web App (required)
#   FRONTEND_DIR             # Path to frontend directory (optional, defaults to ../frontend)
#
# Usage:
#   export WEBAPP_NAME=your-app-name
#   export WEBAPP_RESOURCE_GROUP=your-rg
#   export FRONTEND_DIR=../frontend   # (optional)
#   ./deploy-next-ziponly.sh

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
frontend_dir_default="$repo_root/../frontend"
frontend_dir="${FRONTEND_DIR:-$frontend_dir_default}"

if [[ ! -d "$frontend_dir" ]]; then
  echo "Frontend directory not found: $frontend_dir" >&2
  exit 1
fi

: "${WEBAPP_NAME:?Set WEBAPP_NAME (target Web App name)}"
: "${WEBAPP_RESOURCE_GROUP:?Set WEBAPP_RESOURCE_GROUP (resource group of the Web App)}"

# Create ZIP of frontend (exclude heavy dev artifacts)
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

echo "Deploying ZIP to Web App '$WEBAPP_NAME'"
az webapp deploy \
  --resource-group "$WEBAPP_RESOURCE_GROUP" \
  --name "$WEBAPP_NAME" \
  --src-path "$zip_path" \
  --type zip 1>/dev/null

echo "Deployment complete."
rm -f "$zip_path"; rmdir "$tmpdir" || true
