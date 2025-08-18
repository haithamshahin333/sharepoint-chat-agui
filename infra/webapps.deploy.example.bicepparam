// Example parameter file for standalone Web Apps deployment
// Safe to commit. Replace placeholder values and copy to a non-committed *.bicepparam filename
// (e.g. webapps.deploy.dev.bicepparam) for real deployments.
// All GUIDs, subscription IDs, resource IDs, and names below are illustrative only.

using './webapps.deploy.bicep'

// =============================================================
// === 1. Deployment scope & metadata ===========================
// =============================================================
// location: Region where the resource group (and most resources) reside.
// NOTE: Not set here so the module's default (resourceGroup().location) is used.
// To override, uncomment and set a literal, e.g.:
// param location = 'eastus2'

// tags: Add standard governance / FinOps tags here. Extend as needed.
param tags = {
  env: 'dev'
  workload: 'demo-web'
  owner: 'team-platform'
  costCenter: 'cc-0000'
}

// =============================================================
// === 2. Feature toggles =======================================
// =============================================================
// deployWebApps: Set to false to skip provisioning the App Service Plan & Web Apps (DNS zones are also skipped).
param deployWebApps = true

// =============================================================
// === 3. Core network integration & DNS =======================
// =============================================================
// vnetResourceId: REQUIRED. The existing VNet that contains:
//   - Integration subnet (for outbound / VNet integration)
//   - Private Endpoints subnet (for PEs to the web apps)
// Example format (replace all segments):
//   /subscriptions/<SUB_ID>/resourceGroups/<RG_NAME>/providers/Microsoft.Network/virtualNetworks/<VNET_NAME>
param vnetResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-network-demo/providers/Microsoft.Network/virtualNetworks/vnet-hub'

// appIntegrationSubnetName: Name of existing subnet for app integration (delegated to Microsoft.Web usually not required).
param appIntegrationSubnetName = 'app-integration'

// peSubnetName: Name of existing subnet for Private Endpoints (no delegation, with network policies disabled for PEs).
param peSubnetName = 'private-endpoints'

// Private DNS zones:
// Provide existing zone resource IDs to REUSE them (multi-environment sharing) OR leave blank to let the template create new zones & VNet links.
// If you supply the main websites zone, the scm zone records will be placed inside it (template will not create the scm zone).
// Examples (keep blank unless you truly share):
//   /subscriptions/<SUB_ID>/resourceGroups/<RG_NAME>/providers/Microsoft.Network/privateDnsZones/privatelink.azurewebsites.net
//   /subscriptions/<SUB_ID>/resourceGroups/<RG_NAME>/providers/Microsoft.Network/privateDnsZones/privatelink.scm.azurewebsites.net
param privateDnsZoneWebsitesResourceIdForWebApps = ''
param privateDnsZoneWebsitesScmResourceId = ''

// =============================================================
// === 4. App Service Plan & runtime ============================
// =============================================================
// appServicePlanName: Leave '' to auto-generate a stable name. Provide for cross-template references or if enforcing naming policy.
param appServicePlanName = ''

// SKU: Production tiers typically P1v3/P2v3/P3v3. For dev/test you might use P0v3 (if available) or consider lower cost plan.
// NOTE: Tier is inferred as PremiumV3. Only specify the size (e.g. P1v3).
param appServicePlanSku = 'P1v3'

// nodeLts: Node version for Next.js site. Keep aligned with supported LTS (e.g., 22-lts, 20-lts).
param nodeLts = '22-lts'

// =============================================================
// === 5. Naming overrides (optional) ===========================
// =============================================================
// Leave blank for deterministic unique names. Override for DNS / branding / cross-env consistency.
param webPythonAppName = ''     // e.g. 'api-demo'
param webNextAppName = ''       // e.g. 'web-frontend'

// =============================================================
// === 6. Optional role assignments for backend web app =========
// =============================================================
// The module can assign RBAC to the (SystemAssigned) identity of the backend Python web app.
// Provide resource IDs for downstream services if you want automatic role assignments.
// Leave blank to skip (or use the create*RoleAssignment toggles below).
// Examples:
//   Storage Account: /subscriptions/<SUB_ID>/resourceGroups/<RG>/providers/Microsoft.Storage/storageAccounts/<STORAGE_NAME>
//   Azure AI Search: /subscriptions/<SUB_ID>/resourceGroups/<RG>/providers/Microsoft.Search/searchServices/<SEARCH_NAME>
//   OpenAI (Cognitive): /subscriptions/<SUB_ID>/resourceGroups/<RG>/providers/Microsoft.CognitiveServices/accounts/<OPENAI_NAME>
param storageAccountResourceId = ''
param searchServiceResourceId = ''
param openAiAccountResourceId = ''

// Role assignment toggles: Set to false if roles are already granted or managed elsewhere (e.g. centralized RBAC pipeline).
param createStorageRoleAssignment = true
param createSearchRoleAssignment = true
param createOpenAiRoleAssignment = true

// =============================================================
// === 7. Deployment instance discriminator =====================
// =============================================================
// deploymentInstance: Auto-generated in the module by default.
// Only override (provide a 6-char lowercase string) if coordinating multiple concurrent deployments.
// Example:
// param deploymentInstance = 'a1b2c3'

// =============================================================
// === 8. Quick customization checklist =========================
// =============================================================
// Minimum edits required for a functional deployment:
//   1. Update vnetResourceId to point to an existing VNet with required subnets.
//   2. (Optional) Provide existing private DNS zone IDs if reusing shared zones.
//   3. (Optional) Provide downstream resource IDs for automatic RBAC.
//   4. (Optional) Set deterministic names for webPythonAppName/webNextAppName.
//   5. Adjust tags.
// Deploy: az deployment group create -g <rg> -f infra/webapps.deploy.bicep -p @infra/<your>.bicepparam
// (Or include in larger orchestration via module.)

// =============================================================
// === 9. Security / Ops Notes ==================================
// =============================================================
// - No secrets are stored here. App settings / connection strings should be supplied via deployment automation or Key Vault references.
// - When reusing private DNS zones across environments, enforce naming conventions to avoid record collisions.
// - Review RBAC assignments periodically; least privilege principle.
// - Consider separate resource groups per environment tier (dev/test/prod) for access boundary & cost tracking.

// End of file.
