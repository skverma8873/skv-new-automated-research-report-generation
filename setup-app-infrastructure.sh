#!/bin/bash
set -euo pipefail

# Setup Application Infrastructure for Research Report Generation System
# Creates: Resource Group, ACR, Log Analytics workspace, Container Apps Environment, File Share

# -------------------------
# Configuration
# -------------------------
APP_RESOURCE_GROUP="research-report-app-rg"
LOCATION="eastus"
APP_ACR_NAME="researchreportacrskv"
CONTAINER_ENV="research-report-env"
# Generate unique storage account name (max 24 chars, lowercase, alphanumeric only)
STORAGE_ACCOUNT="reportapp$(date +%s | tail -c 7)"
FILE_SHARE="generated-reports"
LAW_NAME="${APP_RESOURCE_GROUP}-law"   # Log Analytics Workspace name

# Optional: pass subscription id as first argument or rely on default
SUBSCRIPTION_ID="${1:-${AZURE_SUBSCRIPTION_ID:-}}"

log(){ printf '%s\n' "$*" >&2; }

# Verify Azure login
if ! az account show &>/dev/null; then
  log "Not logged in to Azure. Please run 'az login' first."
  exit 1
fi

# Set subscription if provided
if [ -n "${SUBSCRIPTION_ID:-}" ]; then
  az account set --subscription "$SUBSCRIPTION_ID"
else
  SUBSCRIPTION_ID=$(az account show --query id -o tsv)
fi
log "Using subscription: $SUBSCRIPTION_ID"

# Helper to register a provider and wait
register_provider_wait() {
  local NS="$1"
  log "Registering provider: $NS (may take a minute)..."
  az provider register -n "$NS" --subscription "$SUBSCRIPTION_ID" --wait
  log "Provider $NS registration requested/completed."
}

# Ensure required providers are registered
for prov in "Microsoft.OperationalInsights" "Microsoft.App" "Microsoft.Web" "Microsoft.ContainerRegistry" "Microsoft.Storage"; do
  register_provider_wait "$prov"
done

# Create Resource Group
log "Creating App Resource Group: $APP_RESOURCE_GROUP..."
az group create --name "$APP_RESOURCE_GROUP" --location "$LOCATION" --subscription "$SUBSCRIPTION_ID" >/dev/null

# Create Storage Account for Reports
log "Creating Storage Account: $STORAGE_ACCOUNT..."
az storage account create \
  --resource-group "$APP_RESOURCE_GROUP" \
  --name "$STORAGE_ACCOUNT" \
  --location "$LOCATION" \
  --sku Standard_LRS \
  --subscription "$SUBSCRIPTION_ID"

# Get Storage Account Key
STORAGE_KEY=$(az storage account keys list \
  --resource-group "$APP_RESOURCE_GROUP" \
  --account-name "$STORAGE_ACCOUNT" \
  --subscription "$SUBSCRIPTION_ID" \
  --query '[0].value' -o tsv | tr -d '\r' | xargs)

if [ -z "${STORAGE_KEY:-}" ]; then
  log "ERROR: could not obtain storage account key."
  exit 1
fi

# Create File Share for Reports
log "Creating File Share: $FILE_SHARE..."
az storage share create \
  --name "$FILE_SHARE" \
  --account-name "$STORAGE_ACCOUNT" \
  --account-key "$STORAGE_KEY" \
  --subscription "$SUBSCRIPTION_ID" >/dev/null

# Create Azure Container Registry
log "Creating Container Registry: $APP_ACR_NAME..."
az acr create \
  --resource-group "$APP_RESOURCE_GROUP" \
  --name "$APP_ACR_NAME" \
  --sku Basic \
  --admin-enabled true \
  --subscription "$SUBSCRIPTION_ID"

# Get ACR credentials
ACR_USERNAME=$(az acr credential show \
  --name "$APP_ACR_NAME" \
  --subscription "$SUBSCRIPTION_ID" \
  --query username -o tsv | tr -d '\r' | xargs)

ACR_PASSWORD=$(az acr credential show \
  --name "$APP_ACR_NAME" \
  --subscription "$SUBSCRIPTION_ID" \
  --query passwords[0].value -o tsv | tr -d '\r' | xargs)

# Create Log Analytics workspace (required by Container Apps environment)
log "Creating Log Analytics workspace: $LAW_NAME..."
LAW_RESOURCE_ID=$(az monitor log-analytics workspace create \
  --resource-group "$APP_RESOURCE_GROUP" \
  --workspace-name "$LAW_NAME" \
  --location "$LOCATION" \
  --query id -o tsv \
  --subscription "$SUBSCRIPTION_ID" || true)

if [ -z "${LAW_RESOURCE_ID:-}" ]; then
  log "ERROR: failed to create or retrieve Log Analytics workspace resource id."
  exit 1
fi
log "Log Analytics workspace resource id: $LAW_RESOURCE_ID"

# retrieve workspace customerId (GUID) and shared key
log "Retrieving Log Analytics workspace customerId (GUID)..."
LAW_CUSTOMER_ID=$(az monitor log-analytics workspace show \
  --resource-group "$APP_RESOURCE_GROUP" \
  --workspace-name "$LAW_NAME" \
  --query customerId -o tsv --subscription "$SUBSCRIPTION_ID" 2>/dev/null | tr -d '\r' | xargs || true)

if [ -z "${LAW_CUSTOMER_ID:-}" ]; then
  log "ERROR: failed to obtain Log Analytics workspace customerId. Ensure workspace exists and you have permission."
  exit 1
fi
log "Log Analytics customerId: $LAW_CUSTOMER_ID"

log "Retrieving Log Analytics workspace shared key..."
LAW_KEY=$(az monitor log-analytics workspace get-shared-keys \
  --resource-group "$APP_RESOURCE_GROUP" \
  --workspace-name "$LAW_NAME" \
  --query primarySharedKey -o tsv --subscription "$SUBSCRIPTION_ID" 2>/dev/null | tr -d '\r' | xargs || true)

if [ -z "${LAW_KEY:-}" ]; then
  log "ERROR: failed to obtain Log Analytics workspace shared key. Ensure you have permission to read workspace keys."
  log "You can run: az monitor log-analytics workspace get-shared-keys -g $APP_RESOURCE_GROUP -n $LAW_NAME"
  exit 1
fi
log "Log Analytics workspace key retrieved."

# Create Container Apps Environment with workspace (pass workspace id GUID and key)
# NOTE: containerapp env create expects the workspace "customerId" GUID via --logs-workspace-id
log "Creating Container Apps Environment: $CONTAINER_ENV using Log Analytics workspace..."
az containerapp env create \
  --name "$CONTAINER_ENV" \
  --resource-group "$APP_RESOURCE_GROUP" \
  --location "$LOCATION" \
  --logs-workspace-id "$LAW_CUSTOMER_ID" \
  --logs-workspace-key "$LAW_KEY" \
  --subscription "$SUBSCRIPTION_ID"

echo ""
echo "╔════════════════════════════════════════════════════════╗"
echo "║           Setup Complete!                              ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""
echo "┌─────────────────────────────────────────────────────────┐"
echo "│ Credential ID: acr-username                             │"
echo "│ Value: $ACR_USERNAME"
echo "└─────────────────────────────────────────────────────────┘"
echo ""
echo "┌─────────────────────────────────────────────────────────┐"
echo "│ Credential ID: acr-password                             │"
echo "│ Value: $ACR_PASSWORD"
echo "└─────────────────────────────────────────────────────────┘"
echo ""
echo "┌─────────────────────────────────────────────────────────┐"
echo "│ Credential ID: storage-account-name                     │"
echo "│ Value: $STORAGE_ACCOUNT"
echo "└─────────────────────────────────────────────────────────┘"
echo ""
echo "┌─────────────────────────────────────────────────────────┐"
echo "│ Credential ID: storage-account-key                      │"
echo "│ Value: $STORAGE_KEY"
echo "└─────────────────────────────────────────────────────────┘"
echo "" 

# ...existing code...
echo "┌─────────────────────────────────────────────────────────┐"
echo "│ Subscription ID                                         │"
echo "│ Value: $SUBSCRIPTION_ID"
echo "└─────────────────────────────────────────────────────────┘"
echo ""
# ...existing code...