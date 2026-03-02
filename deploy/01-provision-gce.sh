#!/usr/bin/env bash
# =============================================================================
# 01-provision-gce.sh — Provision Google Cloud Compute Engine VM for Ghost
# =============================================================================
# Prerequisites:
#   - gcloud CLI authenticated: gcloud auth login
#   - Project set: gcloud config set project dolphin-vertex-ai
#   - AWS CLI configured (for Route 53 DNS update)
#   - jq installed: brew install jq
#
# Usage:
#   chmod +x deploy/01-provision-gce.sh
#   ./deploy/01-provision-gce.sh
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
PROJECT="dolphin-vertex-ai"
ZONE="us-central1-a"
REGION="us-central1"
INSTANCE_NAME="ghost-newsletter"
MACHINE_TYPE="e2-small"          # 2 vCPU shared, 2GB RAM — ~$14/mo
DISK_SIZE="30GB"
DISK_TYPE="pd-balanced"
IMAGE_FAMILY="ubuntu-2204-lts"
IMAGE_PROJECT="ubuntu-os-cloud"
FIREWALL_RULE="ghost-allow-web"
STATIC_IP_NAME="ghost-newsletter-ip"
GHOST_DOMAIN="newsletter.dolphinwebdynamics.com"
HOSTED_ZONE_NAME="dolphinwebdynamics-com"   # Route 53 hosted zone name

# ---------------------------------------------------------------------------
# Validate prerequisites
# ---------------------------------------------------------------------------
command -v gcloud >/dev/null 2>&1 || { echo "ERROR: gcloud CLI not found. Install from https://cloud.google.com/sdk/docs/install"; exit 1; }
command -v aws    >/dev/null 2>&1 || { echo "ERROR: aws CLI not found. Install from https://aws.amazon.com/cli/"; exit 1; }
command -v jq     >/dev/null 2>&1 || { echo "ERROR: jq not found. Run: brew install jq"; exit 1; }

echo "==> Project: $PROJECT"
echo "==> Zone:    $ZONE"

gcloud config set project "$PROJECT" --quiet

# ---------------------------------------------------------------------------
# Step 1: Create firewall rule (tcp:22,80,443)
# ---------------------------------------------------------------------------
echo "==> Creating firewall rule: $FIREWALL_RULE..."
if gcloud compute firewall-rules describe "$FIREWALL_RULE" --project="$PROJECT" &>/dev/null; then
  echo "    Firewall rule already exists — skipping"
else
  gcloud compute firewall-rules create "$FIREWALL_RULE" \
    --project="$PROJECT" \
    --allow="tcp:22,tcp:80,tcp:443" \
    --source-ranges="0.0.0.0/0" \
    --description="Ghost newsletter: SSH, HTTP, HTTPS" \
    --target-tags="ghost-newsletter"
  echo "    Firewall rule created"
fi

# ---------------------------------------------------------------------------
# Step 2: Reserve static external IP
# ---------------------------------------------------------------------------
echo "==> Reserving static external IP: $STATIC_IP_NAME..."
if gcloud compute addresses describe "$STATIC_IP_NAME" --region="$REGION" --project="$PROJECT" &>/dev/null; then
  echo "    Static IP already reserved — skipping"
else
  gcloud compute addresses create "$STATIC_IP_NAME" \
    --region="$REGION" \
    --project="$PROJECT"
  echo "    Static IP reserved"
fi

STATIC_IP=$(gcloud compute addresses describe "$STATIC_IP_NAME" \
  --region="$REGION" \
  --project="$PROJECT" \
  --format="get(address)")
echo "    Static IP: $STATIC_IP"

# ---------------------------------------------------------------------------
# Step 3: Launch e2-small instance
# ---------------------------------------------------------------------------
echo "==> Launching VM ($MACHINE_TYPE, $DISK_SIZE $DISK_TYPE disk)..."
if gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" --project="$PROJECT" &>/dev/null; then
  echo "    Instance already exists — skipping launch"
else
  gcloud compute instances create "$INSTANCE_NAME" \
    --project="$PROJECT" \
    --zone="$ZONE" \
    --machine-type="$MACHINE_TYPE" \
    --image-family="$IMAGE_FAMILY" \
    --image-project="$IMAGE_PROJECT" \
    --boot-disk-size="$DISK_SIZE" \
    --boot-disk-type="$DISK_TYPE" \
    --boot-disk-device-name="$INSTANCE_NAME" \
    --address="$STATIC_IP" \
    --tags="ghost-newsletter" \
    --metadata="enable-oslogin=TRUE"
  echo "    VM launched"
fi

# ---------------------------------------------------------------------------
# Step 4: Add Route 53 A record for newsletter subdomain
# ---------------------------------------------------------------------------
echo "==> Updating Route 53 DNS: $GHOST_DOMAIN → $STATIC_IP..."

ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name "dolphinwebdynamics.com." \
  --query 'HostedZones[0].Id' \
  --output text | sed 's|/hostedzone/||')

if [[ -z "$ZONE_ID" || "$ZONE_ID" == "None" ]]; then
  echo "    ERROR: Route 53 hosted zone for dolphinwebdynamics.com not found."
  echo "    Manually create an A record: $GHOST_DOMAIN → $STATIC_IP"
else
  CHANGE_BATCH=$(cat <<JSON
{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "$GHOST_DOMAIN",
      "Type": "A",
      "TTL": 300,
      "ResourceRecords": [{"Value": "$STATIC_IP"}]
    }
  }]
}
JSON
)
  aws route53 change-resource-record-sets \
    --hosted-zone-id "$ZONE_ID" \
    --change-batch "$CHANGE_BATCH" \
    > /dev/null
  echo "    DNS record upserted (TTL 300s)"
fi

# ---------------------------------------------------------------------------
# Output summary
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "$STATIC_IP" > "${SCRIPT_DIR}/.vm-public-ip"

echo ""
echo "============================================================"
echo "  PROVISIONING COMPLETE"
echo "============================================================"
echo "  Instance    : $INSTANCE_NAME ($MACHINE_TYPE)"
echo "  Zone        : $ZONE"
echo "  Public IP   : $STATIC_IP (static)"
echo "  DNS         : $GHOST_DOMAIN → $STATIC_IP"
echo ""
echo "  Next steps:"
echo "  1. Wait ~2 minutes for VM to fully boot"
echo "  2. Check DNS propagation:"
echo "     dig $GHOST_DOMAIN A +short"
echo "     (should return $STATIC_IP)"
echo ""
echo "  3. Copy files and install Ghost:"
echo "     gcloud compute scp deploy/02-install-ghost.sh ${INSTANCE_NAME}:~/ --zone=$ZONE"
echo "     gcloud compute scp deploy/config.production.json ${INSTANCE_NAME}:~/ --zone=$ZONE"
echo "     gcloud compute ssh $INSTANCE_NAME --zone=$ZONE -- 'bash ~/02-install-ghost.sh'"
echo "============================================================"
echo "  (IP saved to deploy/.vm-public-ip)"
