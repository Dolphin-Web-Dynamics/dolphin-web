#!/usr/bin/env bash
# =============================================================================
# retry-launch-vm.sh — Retry Oracle VM launch until capacity is available
# =============================================================================
# Oracle Always Free A1.Flex capacity in Phoenix is often exhausted.
# This script retries every 5 minutes across all 3 ADs until it succeeds.
#
# Usage:
#   chmod +x deploy/retry-launch-vm.sh
#   nohup ./deploy/retry-launch-vm.sh > /tmp/oci-retry.log 2>&1 &
#   tail -f /tmp/oci-retry.log
#
# To stop: kill $(pgrep -f retry-launch-vm)
# =============================================================================

set -euo pipefail

COMPARTMENT_ID="ocid1.tenancy.oc1..aaaaaaaamddsmi2zpw7ls5m2nv3txnt2muhagfd7vaq54parmbwiah4uegpa"
SUBNET_ID="ocid1.subnet.oc1.phx.aaaaaaaalxrod6tg3q45ugu4u32zdn7zradz7xlemmecczovoujfokdh4zha"
UBUNTU_IMAGE_ID="ocid1.image.oc1.phx.aaaaaaaahzur55ghl5ypjy27zsuh7adac4ppnofrp2d3wuxu7iam4ibgkaia"
SSH_KEY="/Users/anelcanto/.ssh/ghost-oracle.pub"
ADS=("axYl:PHX-AD-1" "axYl:PHX-AD-2" "axYl:PHX-AD-3")
RETRY_INTERVAL=300  # 5 minutes between full cycles
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

attempt=0
start_time=$(date +%s)

echo "==> Starting VM launch retry loop"
echo "==> Trying all Phoenix ADs every ${RETRY_INTERVAL}s"
echo "==> Log: /tmp/oci-retry.log"
echo ""

while true; do
  attempt=$((attempt + 1))
  elapsed=$(( ($(date +%s) - start_time) / 60 ))
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Attempt #${attempt} (${elapsed}m elapsed)"

  for AD in "${ADS[@]}"; do
    echo "  Trying $AD..."
    RESULT=$(oci compute instance launch \
      --compartment-id "$COMPARTMENT_ID" \
      --availability-domain "$AD" \
      --shape "VM.Standard.A1.Flex" \
      --shape-config '{"ocpus":2,"memoryInGBs":12}' \
      --image-id "$UBUNTU_IMAGE_ID" \
      --subnet-id "$SUBNET_ID" \
      --display-name "ghost-newsletter" \
      --assign-public-ip true \
      --ssh-authorized-keys-file "$SSH_KEY" \
      --boot-volume-size-in-gbs 50 2>&1 || true)

    if echo "$RESULT" | grep -q '"lifecycle-state"'; then
      INSTANCE_ID=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data']['id'])" 2>/dev/null)
      echo ""
      echo "============================================================"
      echo "  SUCCESS! VM launched in $AD"
      echo "  Instance ID: $INSTANCE_ID"
      echo "============================================================"

      # Save instance ID
      echo "$INSTANCE_ID" > "${SCRIPT_DIR}/.instance-id"

      # Wait for RUNNING state and get public IP
      echo "  Waiting for RUNNING state..."
      sleep 30
      for i in {1..20}; do
        STATE=$(oci compute instance get \
          --instance-id "$INSTANCE_ID" \
          --query 'data."lifecycle-state"' \
          --raw-output 2>/dev/null || echo "UNKNOWN")
        echo "  State: $STATE (check $i/20)"
        if [[ "$STATE" == "RUNNING" ]]; then
          sleep 10
          PUBLIC_IP=$(oci compute instance list-vnics \
            --instance-id "$INSTANCE_ID" \
            --query 'data[0]."public-ip"' \
            --raw-output 2>/dev/null)
          echo ""
          echo "============================================================"
          echo "  INSTANCE RUNNING"
          echo "  Public IP: $PUBLIC_IP"
          echo "  SSH: ssh -i ~/.ssh/ghost-oracle ubuntu@$PUBLIC_IP"
          echo "============================================================"
          echo "$PUBLIC_IP" > "${SCRIPT_DIR}/.vm-public-ip"
          echo ""
          echo "  Next: Add DNS A record, then copy and run 02-install-ghost.sh"
          echo "  See README.md for full instructions"
          exit 0
        fi
        sleep 15
      done
      echo "  Instance launched but state check timed out. Check OCI console."
      exit 0
    fi

    MSG=$(echo "$RESULT" | grep '"message"' | sed 's/.*"message": "\(.*\)".*/\1/')
    echo "  $AD: $MSG"
  done

  echo "  All ADs at capacity. Waiting ${RETRY_INTERVAL}s before retry..."
  echo ""
  sleep $RETRY_INTERVAL
done
