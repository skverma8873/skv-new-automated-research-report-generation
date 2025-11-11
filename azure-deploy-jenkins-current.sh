# ...existing code...
#!/bin/bash

# Azure Deployment Script for Jenkins
# Deploys Jenkins with Python 3.11 and Azure CLI for Research Report Generation CI/CD

set -e

# Configuration
RESOURCE_GROUP="research-report-jenkins-rg"
LOCATION="eastus"
STORAGE_ACCOUNT="reportjenkinsstoreskv"
FILE_SHARE="jenkins-data"
ACR_NAME_BASE="researchreportacr"
CONTAINER_NAME="jenkins-research-report"
DNS_NAME_LABEL="jenkins-research-$(date +%s | tail -c 6)"
JENKINS_IMAGE_NAME="custom-jenkins"
JENKINS_IMAGE_TAG="lts-git-configured"

# Subscription ID - can be passed as argument or environment variable
SUBSCRIPTION_ID="${1:-${AZURE_SUBSCRIPTION_ID}}"

echo "╔════════════════════════════════════════════════════════╗"
echo "║  Deploying Jenkins for Research Report Generation     ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""

# Verify Azure login
echo "Verifying Azure login..."
if ! az account show &>/dev/null; then
    echo "Not logged in to Azure. Please run 'az login' first."
    exit 1
fi

# Set subscription if provided
if [ -n "$SUBSCRIPTION_ID" ]; then
    echo "Setting Azure subscription to: $SUBSCRIPTION_ID"
    az account set --subscription "$SUBSCRIPTION_ID"
    if [ $? -ne 0 ]; then
        echo "Failed to set subscription. Please verify the subscription ID."
        exit 1
    fi
else
    echo "ℹ️ No subscription ID provided. Using current default subscription."
    CURRENT_SUB=$(az account show --query id -o tsv)
    echo "   Current subscription: $CURRENT_SUB"
fi

# Verify subscription is set correctly
CURRENT_SUB=$(az account show --query id -o tsv)
echo "Using subscription: $CURRENT_SUB"
echo ""

# Store subscription ID for use in commands
if [ -z "$SUBSCRIPTION_ID" ]; then
    SUBSCRIPTION_ID="$CURRENT_SUB"
fi

# -------------------------------------------------------------------
# Ensure required resource providers are registered
# -------------------------------------------------------------------
register_provider() {
  local NAMESPACE="$1"
  local SUB="$2"
  local TIMEOUT="${3:-300}"   # seconds
  local INTERVAL="${4:-5}"

  echo "Checking provider registration for: $NAMESPACE"
  local STATE
  STATE=$(az provider show --namespace "$NAMESPACE" --subscription "$SUB" --query "registrationState" -o tsv 2>/dev/null || echo "NotRegistered")
  if [ "$STATE" = "Registered" ]; then
    echo "Provider $NAMESPACE already registered."
    return 0
  fi

  echo "Registering provider $NAMESPACE..."
  az provider register --namespace "$NAMESPACE" --subscription "$SUB" || true

  local ELAPSED=0
  while [ $ELAPSED -lt $TIMEOUT ]; do
    STATE=$(az provider show --namespace "$NAMESPACE" --subscription "$SUB" --query "registrationState" -o tsv 2>/dev/null || echo "NotRegistered")
    echo "  $NAMESPACE registration state: $STATE"
    if [ "$STATE" = "Registered" ]; then
      echo "Provider $NAMESPACE registered successfully."
      return 0
    fi
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
  done

  echo "Timed out waiting for provider $NAMESPACE to register. Current state: $STATE"
  return 1
}

# Register commonly required providers (add or remove as needed)
for prov in "Microsoft.ContainerInstance" "Microsoft.ContainerRegistry" "Microsoft.Storage"; do
  if ! register_provider "$prov" "$SUBSCRIPTION_ID" 300 5; then
    echo ""
    echo "ERROR: Provider registration failed for $prov. You may need Owner permissions or ask your subscription admin to register it."
    echo "Run: az provider register --namespace $prov --subscription $SUBSCRIPTION_ID"
    exit 1
  fi
done

# -------------------------------------------------------------------
# ACR name availability helper - returns a valid available name or exits
# -------------------------------------------------------------------
# ...existing code...
generate_acr_name() {
  local base="$1"
  local sub="$2"
  local max_attempts=12

  # normalize base: lowercase, alphanumeric
  base=$(echo "$base" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g' | cut -c1-40)
  if [ -z "$base" ]; then
    base="acr$(date +%s | tail -c 6)"
  fi

  for i in $(seq 1 $max_attempts); do
    if [ "$i" -eq 1 ]; then
      candidate="$base"
    else
      if command -v openssl >/dev/null 2>&1; then
        suffix=$(openssl rand -hex 3)
      elif command -v uuidgen >/dev/null 2>&1; then
        suffix=$(uuidgen | tr -dc 'a-f0-9' | cut -c1-6)
      else
        suffix=$(date +%s | tail -c 6)
      fi
      candidate="${base}${suffix}"
    fi

    # ensure length bounds (5-50)
    candidate=$(echo "$candidate" | cut -c1-50)
    if [ "${#candidate}" -lt 5 ]; then
      candidate="${candidate}$(date +%s | tail -c 5)"
      candidate=$(echo "$candidate" | cut -c1-50)
    fi

    # debug to stderr only
    >&2 echo "Checking ACR name availability: $candidate"
    available=$(az acr check-name --name "$candidate" --subscription "$sub" --query nameAvailable -o tsv 2>/dev/null || echo "false")
    if [ "$available" = "true" ]; then
      # print chosen name to stdout with newline (safe for command substitution)
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}
# ...existing code...

# Generate or pick an available ACR name
echo "Selecting Azure Container Registry name..." >&2
# capture stdout only and sanitize: keep last non-empty line, strip CR/newline and trim spaces
ACR_NAME="$(generate_acr_name "$ACR_NAME_BASE" "$SUBSCRIPTION_ID" 2>/dev/null | awk 'NF{line=$0} END{print line}' | tr -d '\r' | xargs)"
if [ -z "$ACR_NAME" ]; then
  echo "ERROR: Unable to find an available ACR name after several attempts. Please choose a unique name and rerun." >&2
  exit 1
fi
echo "Using ACR name: $ACR_NAME"
# ...existing code...

# Create Azure Container Registry
echo "Creating Container Registry: $ACR_NAME..."
az acr create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$ACR_NAME" \
  --sku Basic \
  --admin-enabled true \
  --subscription "$SUBSCRIPTION_ID"

# Login to ACR
echo "Logging in to Azure Container Registry..."
az acr login --name "$ACR_NAME"

# Build custom Jenkins image with Git and safe.directory configuration
echo "Building custom Jenkins Docker image for Linux AMD64..."
docker build --platform linux/amd64 -f Dockerfile.jenkins -t "${ACR_NAME}.azurecr.io/${JENKINS_IMAGE_NAME}:${JENKINS_IMAGE_TAG}" .

# Push Jenkins image to ACR with retry logic
echo "Pushing Jenkins image to ACR..."
MAX_RETRIES=3
RETRY_COUNT=0

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  if docker push ${ACR_NAME}.azurecr.io/${JENKINS_IMAGE_NAME}:${JENKINS_IMAGE_TAG}; then
    echo "Image pushed successfully!"
    break
  else
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
      echo "Push failed. Retrying ($RETRY_COUNT/$MAX_RETRIES)..."
      sleep 5
    else
      echo "Failed to push image after $MAX_RETRIES attempts."
      echo ""
      echo "This can happen due to network issues or large image size."
      echo ""
      echo "Options to fix:"
      echo "1. Re-run the script (it will use cached layers and be faster)"
      echo "2. Check your internet connection"
      echo "3. Try pushing manually:"
      echo "   az acr login --name $ACR_NAME"
      echo "   docker push ${ACR_NAME}.azurecr.io/${JENKINS_IMAGE_NAME}:${JENKINS_IMAGE_TAG}"
      exit 1
    fi
  fi
done

# Get ACR credentials for container deployment
echo "Retrieving ACR credentials..."
ACR_USERNAME=$(az acr credential show \
  --name $ACR_NAME \
  --subscription "$SUBSCRIPTION_ID" \
  --query username -o tsv)

ACR_PASSWORD=$(az acr credential show \
  --name $ACR_NAME \
  --subscription "$SUBSCRIPTION_ID" \
  --query passwords[0].value -o tsv)

# Deploy Jenkins Container using custom image
echo "Deploying Jenkins Container..."
az container create \
  --resource-group $RESOURCE_GROUP \
  --name $CONTAINER_NAME \
  --image ${ACR_NAME}.azurecr.io/${JENKINS_IMAGE_NAME}:${JENKINS_IMAGE_TAG} \
  --registry-login-server ${ACR_NAME}.azurecr.io \
  --registry-username $ACR_USERNAME \
  --registry-password $ACR_PASSWORD \
  --os-type Linux \
  --dns-name-label $DNS_NAME_LABEL \
  --ports 8080 \
  --cpu 2 \
  --memory 4 \
  --azure-file-volume-account-name $STORAGE_ACCOUNT \
  --azure-file-volume-account-key $STORAGE_KEY \
  --azure-file-volume-share-name $FILE_SHARE \
  --azure-file-volume-mount-path //var/jenkins_home \
  --environment-variables JAVA_OPTS="-Djenkins.install.runSetupWizard=true" \
  --subscription "$SUBSCRIPTION_ID"

# Wait for deployment
echo "Waiting for Jenkins to deploy..."
sleep 10

# Get Jenkins URL
JENKINS_URL=$(az container show \
  --resource-group $RESOURCE_GROUP \
  --name $CONTAINER_NAME \
  --subscription "$SUBSCRIPTION_ID" \
  --query ipAddress.fqdn -o tsv)

echo ""
echo "╔════════════════════════════════════════════════════════╗"
echo "║           Deployment Complete!                         ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""
echo "Jenkins URL: http://$JENKINS_URL:8080"
echo ""
echo "Wait 2-3 minutes for Jenkins to fully start, then run:"
echo ""
echo "az container exec \\"
echo "  --resource-group $RESOURCE_GROUP \\"
echo "  --name $CONTAINER_NAME \\"
echo "  --exec-command 'cat /var/jenkins_home/secrets/initialAdminPassword'"
echo ""
echo "Save this information for the next steps!"
# ...existing code...