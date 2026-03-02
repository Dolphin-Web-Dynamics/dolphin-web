#!/usr/bin/env bash
# =============================================================================
# 01-provision-vm.sh — Provision Oracle Cloud Always Free VM for Ghost
# =============================================================================
# Prerequisites:
#   - OCI CLI configured: oci setup config (tenancy anel49, region us-phoenix-1)
#   - jq installed: brew install jq
#   - Your OCI compartment OCID set in OCI_COMPARTMENT_ID below
#
# Usage:
#   chmod +x deploy/01-provision-vm.sh
#   ./deploy/01-provision-vm.sh
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — edit these values
# ---------------------------------------------------------------------------
COMPARTMENT_ID="${OCI_COMPARTMENT_ID:-}"   # export OCI_COMPARTMENT_ID=ocid1.compartment...
REGION="us-phoenix-1"
DISPLAY_NAME="ghost-newsletter"
SSH_KEY_PATH="$HOME/.ssh/ghost-oracle"
SHAPE="VM.Standard.A1.Flex"
OCPUS=2
MEMORY_GB=12

# Ubuntu 22.04 ARM64 — canonical image in us-phoenix-1 (2026.01.29)
UBUNTU_IMAGE_ID="ocid1.image.oc1.phx.aaaaaaaahzur55ghl5ypjy27zsuh7adac4ppnofrp2d3wuxu7iam4ibgkaia"

# ---------------------------------------------------------------------------
# Validate prerequisites
# ---------------------------------------------------------------------------
if [[ -z "$COMPARTMENT_ID" ]]; then
  echo "ERROR: OCI_COMPARTMENT_ID is not set."
  echo "Run: export OCI_COMPARTMENT_ID=\$(oci iam compartment list --query 'data[0].id' --raw-output)"
  exit 1
fi

command -v oci  >/dev/null 2>&1 || { echo "ERROR: oci CLI not found. Install from https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm"; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "ERROR: jq not found. Run: brew install jq"; exit 1; }

echo "==> Compartment: $COMPARTMENT_ID"
echo "==> Region:      $REGION"

# ---------------------------------------------------------------------------
# Step 1: Generate SSH key pair
# ---------------------------------------------------------------------------
if [[ ! -f "$SSH_KEY_PATH" ]]; then
  echo "==> Generating SSH key pair at $SSH_KEY_PATH"
  ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -C "ghost-oracle"
  chmod 600 "$SSH_KEY_PATH"
else
  echo "==> SSH key already exists at $SSH_KEY_PATH — skipping generation"
fi
SSH_PUBLIC_KEY=$(cat "${SSH_KEY_PATH}.pub")

# ---------------------------------------------------------------------------
# Step 2: Create VCN
# ---------------------------------------------------------------------------
echo "==> Creating VCN..."
VCN_ID=$(oci network vcn create \
  --compartment-id "$COMPARTMENT_ID" \
  --cidr-block "10.0.0.0/16" \
  --display-name "${DISPLAY_NAME}-vcn" \
  --dns-label "ghostvcn" \
  --wait-for-state AVAILABLE \
  --query 'data.id' \
  --raw-output)
echo "    VCN ID: $VCN_ID"

# ---------------------------------------------------------------------------
# Step 3: Create Internet Gateway
# ---------------------------------------------------------------------------
echo "==> Creating Internet Gateway..."
IGW_ID=$(oci network internet-gateway create \
  --compartment-id "$COMPARTMENT_ID" \
  --vcn-id "$VCN_ID" \
  --is-enabled true \
  --display-name "${DISPLAY_NAME}-igw" \
  --wait-for-state AVAILABLE \
  --query 'data.id' \
  --raw-output)
echo "    IGW ID: $IGW_ID"

# ---------------------------------------------------------------------------
# Step 4: Update default route table to point to IGW
# ---------------------------------------------------------------------------
echo "==> Configuring route table..."
RT_ID=$(oci network route-table list \
  --compartment-id "$COMPARTMENT_ID" \
  --vcn-id "$VCN_ID" \
  --query 'data[0].id' \
  --raw-output)

oci network route-table update \
  --rt-id "$RT_ID" \
  --route-rules "[{\"cidrBlock\":\"0.0.0.0/0\",\"networkEntityId\":\"${IGW_ID}\"}]" \
  --force \
  --wait-for-state AVAILABLE \
  > /dev/null
echo "    Route Table ID: $RT_ID"

# ---------------------------------------------------------------------------
# Step 5: Create Security List (ports 22, 80, 443)
# ---------------------------------------------------------------------------
echo "==> Creating Security List..."
SL_ID=$(oci network security-list create \
  --compartment-id "$COMPARTMENT_ID" \
  --vcn-id "$VCN_ID" \
  --display-name "${DISPLAY_NAME}-sl" \
  --ingress-security-rules '[
    {"source":"0.0.0.0/0","protocol":"6","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":22,"max":22}}},
    {"source":"0.0.0.0/0","protocol":"6","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":80,"max":80}}},
    {"source":"0.0.0.0/0","protocol":"6","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":443,"max":443}}},
    {"source":"0.0.0.0/0","protocol":"1","isStateless":false,"icmpOptions":{"type":3,"code":4}},
    {"source":"10.0.0.0/16","protocol":"1","isStateless":false,"icmpOptions":{"type":3}}
  ]' \
  --egress-security-rules '[
    {"destination":"0.0.0.0/0","protocol":"all","isStateless":false}
  ]' \
  --wait-for-state AVAILABLE \
  --query 'data.id' \
  --raw-output)
echo "    Security List ID: $SL_ID"

# ---------------------------------------------------------------------------
# Step 6: Create Public Subnet
# ---------------------------------------------------------------------------
echo "==> Creating Public Subnet..."
SUBNET_ID=$(oci network subnet create \
  --compartment-id "$COMPARTMENT_ID" \
  --vcn-id "$VCN_ID" \
  --cidr-block "10.0.1.0/24" \
  --display-name "${DISPLAY_NAME}-subnet" \
  --dns-label "ghostsubnet" \
  --route-table-id "$RT_ID" \
  --security-list-ids "[\"${SL_ID}\"]" \
  --prohibit-public-ip-on-vnic false \
  --wait-for-state AVAILABLE \
  --query 'data.id' \
  --raw-output)
echo "    Subnet ID: $SUBNET_ID"

# ---------------------------------------------------------------------------
# Step 7: Find Availability Domain
# ---------------------------------------------------------------------------
echo "==> Getting Availability Domain..."
AD_NAME=$(oci iam availability-domain list \
  --compartment-id "$COMPARTMENT_ID" \
  --query 'data[0].name' \
  --raw-output)
echo "    AD: $AD_NAME"

# ---------------------------------------------------------------------------
# Step 8: Launch VM.Standard.A1.Flex instance
# ---------------------------------------------------------------------------
echo "==> Launching VM (${SHAPE}, ${OCPUS} OCPUs, ${MEMORY_GB}GB RAM)..."
INSTANCE_ID=$(oci compute instance launch \
  --compartment-id "$COMPARTMENT_ID" \
  --availability-domain "$AD_NAME" \
  --shape "$SHAPE" \
  --shape-config "{\"ocpus\":${OCPUS},\"memoryInGBs\":${MEMORY_GB}}" \
  --image-id "$UBUNTU_IMAGE_ID" \
  --subnet-id "$SUBNET_ID" \
  --display-name "$DISPLAY_NAME" \
  --assign-public-ip true \
  --ssh-authorized-keys-file "${SSH_KEY_PATH}.pub" \
  --boot-volume-size-in-gbs 50 \
  --wait-for-state RUNNING \
  --query 'data.id' \
  --raw-output)
echo "    Instance ID: $INSTANCE_ID"

# ---------------------------------------------------------------------------
# Step 9: Get public IP
# ---------------------------------------------------------------------------
echo "==> Fetching public IP..."
sleep 10  # brief wait for VNIC attachment
PUBLIC_IP=$(oci compute instance list-vnics \
  --instance-id "$INSTANCE_ID" \
  --query 'data[0]."public-ip"' \
  --raw-output)

# ---------------------------------------------------------------------------
# Output summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  PROVISIONING COMPLETE"
echo "============================================================"
echo "  Instance ID : $INSTANCE_ID"
echo "  Public IP   : $PUBLIC_IP"
echo "  SSH Key     : $SSH_KEY_PATH"
echo ""
echo "  Next steps:"
echo "  1. Set DNS A record:"
echo "     newsletter.dolphinwebdynamics.com → $PUBLIC_IP"
echo "     (Use Route 53 — see README.md Step 3)"
echo ""
echo "  2. Wait ~2 min for VM to fully boot, then:"
echo "     ssh -i $SSH_KEY_PATH ubuntu@$PUBLIC_IP"
echo ""
echo "  3. Copy and run the install script:"
echo "     scp -i $SSH_KEY_PATH deploy/02-install-ghost.sh ubuntu@$PUBLIC_IP:~/"
echo "     ssh -i $SSH_KEY_PATH ubuntu@$PUBLIC_IP 'bash ~/02-install-ghost.sh'"
echo "============================================================"

# Save IP for other scripts
echo "$PUBLIC_IP" > deploy/.vm-public-ip
echo "  (Saved to deploy/.vm-public-ip)"
