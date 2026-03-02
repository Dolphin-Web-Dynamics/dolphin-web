#!/usr/bin/env bash
# =============================================================================
# 03-setup-ses.sh — Configure Amazon SES for Ghost email delivery
# =============================================================================
# Prerequisites:
#   - AWS CLI configured: aws configure (or AWS_PROFILE set)
#   - Domain DNS managed in Route 53 (recommended) or external registrar
#
# This script:
#   1. Verifies the domain in SES (us-east-1)
#   2. Generates DKIM keys and outputs CNAME records
#   3. Creates an IAM user + SMTP credentials for Ghost
#   4. Adds DNS records to Route 53 if hosted zone is found
#   5. Prints instructions for SES sandbox removal request
#
# Usage:
#   export AWS_PROFILE=default   # or set AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
#   chmod +x deploy/03-setup-ses.sh
#   ./deploy/03-setup-ses.sh
# =============================================================================

set -euo pipefail

DOMAIN="dolphinwebdynamics.com"
NEWSLETTER_SUBDOMAIN="newsletter.dolphinwebdynamics.com"
SES_REGION="us-east-1"
IAM_USER_NAME="ghost-ses-sender"
VM_PUBLIC_IP_FILE="deploy/.vm-public-ip"

command -v aws  >/dev/null 2>&1 || { echo "ERROR: aws CLI not found. Install: brew install awscli"; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "ERROR: jq not found. Install: brew install jq"; exit 1; }

echo "==> Setting up Amazon SES in region: $SES_REGION"

# ---------------------------------------------------------------------------
# 1. Verify domain in SES
# ---------------------------------------------------------------------------
echo "==> Verifying domain $DOMAIN in SES..."
VERIFICATION_TOKEN=$(aws ses verify-domain-identity \
  --domain "$DOMAIN" \
  --region "$SES_REGION" \
  --query 'VerificationToken' \
  --output text)
echo "    Domain verification token: $VERIFICATION_TOKEN"

# ---------------------------------------------------------------------------
# 2. Enable DKIM for the domain
# ---------------------------------------------------------------------------
echo "==> Generating DKIM keys..."
DKIM_TOKENS=$(aws ses verify-domain-dkim \
  --domain "$DOMAIN" \
  --region "$SES_REGION" \
  --query 'DkimTokens' \
  --output json)

echo "    DKIM tokens generated."

# ---------------------------------------------------------------------------
# 3. Look up Route 53 hosted zone
# ---------------------------------------------------------------------------
echo "==> Looking up Route 53 hosted zone for $DOMAIN..."
HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name "${DOMAIN}." \
  --query "HostedZones[?Name=='${DOMAIN}.'].Id" \
  --output text | sed 's|/hostedzone/||')

if [[ -n "$HOSTED_ZONE_ID" ]]; then
  echo "    Found hosted zone: $HOSTED_ZONE_ID"
  AUTO_DNS=true
else
  echo "    No Route 53 hosted zone found — DNS records must be added manually."
  AUTO_DNS=false
fi

# ---------------------------------------------------------------------------
# 4. Build DNS records for SES
# ---------------------------------------------------------------------------
DKIM_1=$(echo "$DKIM_TOKENS" | jq -r '.[0]')
DKIM_2=$(echo "$DKIM_TOKENS" | jq -r '.[1]')
DKIM_3=$(echo "$DKIM_TOKENS" | jq -r '.[2]')

VM_IP=""
if [[ -f "$VM_PUBLIC_IP_FILE" ]]; then
  VM_IP=$(cat "$VM_PUBLIC_IP_FILE")
fi

# ---------------------------------------------------------------------------
# 5. Add DNS records to Route 53 (if hosted zone found)
# ---------------------------------------------------------------------------
if [[ "$AUTO_DNS" == true ]]; then
  echo "==> Adding DNS records to Route 53..."

  # Build change batch JSON
  CHANGE_BATCH=$(cat << EOF
{
  "Comment": "SES verification + DKIM + DMARC + newsletter subdomain for Ghost",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "_amazonses.${DOMAIN}",
        "Type": "TXT",
        "TTL": 300,
        "ResourceRecords": [{"Value": "\"${VERIFICATION_TOKEN}\""}]
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${DKIM_1}._domainkey.${DOMAIN}",
        "Type": "CNAME",
        "TTL": 300,
        "ResourceRecords": [{"Value": "${DKIM_1}.dkim.amazonses.com"}]
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${DKIM_2}._domainkey.${DOMAIN}",
        "Type": "CNAME",
        "TTL": 300,
        "ResourceRecords": [{"Value": "${DKIM_2}.dkim.amazonses.com"}]
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${DKIM_3}._domainkey.${DOMAIN}",
        "Type": "CNAME",
        "TTL": 300,
        "ResourceRecords": [{"Value": "${DKIM_3}.dkim.amazonses.com"}]
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "_dmarc.${DOMAIN}",
        "Type": "TXT",
        "TTL": 300,
        "ResourceRecords": [{"Value": "\"v=DMARC1; p=none; rua=mailto:dmarc@${DOMAIN}; ruf=mailto:dmarc@${DOMAIN}; fo=1\""}]
      }
    }
  ]
}
EOF
)

  # Add newsletter A record if VM IP is known
  if [[ -n "$VM_IP" ]]; then
    CHANGE_BATCH=$(echo "$CHANGE_BATCH" | jq --arg ip "$VM_IP" --arg sub "$NEWSLETTER_SUBDOMAIN" \
      '.Changes += [{
        "Action": "UPSERT",
        "ResourceRecordSet": {
          "Name": $sub,
          "Type": "A",
          "TTL": 300,
          "ResourceRecords": [{"Value": $ip}]
        }
      }]')
    echo "    Adding A record: $NEWSLETTER_SUBDOMAIN → $VM_IP"
  fi

  aws route53 change-resource-record-sets \
    --hosted-zone-id "$HOSTED_ZONE_ID" \
    --change-batch "$CHANGE_BATCH" \
    > /dev/null

  echo "    Route 53 DNS records applied."
fi

# ---------------------------------------------------------------------------
# 6. Create IAM user + SMTP credentials for Ghost
# ---------------------------------------------------------------------------
echo "==> Creating IAM user: $IAM_USER_NAME..."

# Create user (ignore error if already exists)
aws iam create-user --user-name "$IAM_USER_NAME" > /dev/null 2>&1 || echo "    IAM user already exists — skipping creation"

# Attach SES send policy
aws iam put-user-policy \
  --user-name "$IAM_USER_NAME" \
  --policy-name "SESSendEmail" \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": ["ses:SendEmail", "ses:SendRawEmail"],
      "Resource": "*"
    }]
  }'

# Create access key
echo "==> Creating SMTP credentials..."
SMTP_CREDS=$(aws iam create-access-key --user-name "$IAM_USER_NAME")
ACCESS_KEY_ID=$(echo "$SMTP_CREDS" | jq -r '.AccessKey.AccessKeyId')
SECRET_KEY=$(echo "$SMTP_CREDS" | jq -r '.AccessKey.SecretAccessKey')

# Convert IAM secret key to SMTP password (AWS SES SMTP password derivation)
# See: https://docs.aws.amazon.com/ses/latest/dg/smtp-credentials.html
SMTP_PASSWORD=$(python3 - << PYTHON
import hmac, hashlib, base64
key = "${SECRET_KEY}".encode('utf-8')
message = b"SendRawEmail"
version = b"\x02"
h = hmac.new(key, message, digestmod=hashlib.sha256).digest()
smtp_password = base64.b64encode(version + h).decode('utf-8')
print(smtp_password)
PYTHON
)

# Save credentials to file (never commit this)
CREDS_FILE="deploy/.ses-credentials"
cat > "$CREDS_FILE" << EOF
# Amazon SES SMTP Credentials for Ghost
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# KEEP THIS FILE SECRET — add to .gitignore

SES_REGION=${SES_REGION}
SMTP_HOST=email-smtp.${SES_REGION}.amazonaws.com
SMTP_PORT=587
SMTP_USER=${ACCESS_KEY_ID}
SMTP_PASS=${SMTP_PASSWORD}
FROM_EMAIL=newsletter@${DOMAIN}
FROM_NAME=Dolphin Web Dynamics
EOF
chmod 600 "$CREDS_FILE"

echo "    Credentials saved to $CREDS_FILE (chmod 600)"

# ---------------------------------------------------------------------------
# 7. Output summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  SES SETUP SUMMARY"
echo "============================================================"

if [[ "$AUTO_DNS" == true ]]; then
  echo "  Route 53 DNS records added automatically."
  echo "  Allow 5-10 minutes for propagation."
else
  echo "  MANUAL DNS RECORDS REQUIRED:"
  echo "  Add these to your DNS provider:"
  echo ""
  echo "  Type  Name                                     Value"
  echo "  ----  ---------------------------------------- ----------------------------------------"
  echo "  TXT   _amazonses.$DOMAIN          \"$VERIFICATION_TOKEN\""
  echo "  CNAME ${DKIM_1}._domainkey.$DOMAIN  ${DKIM_1}.dkim.amazonses.com"
  echo "  CNAME ${DKIM_2}._domainkey.$DOMAIN  ${DKIM_2}.dkim.amazonses.com"
  echo "  CNAME ${DKIM_3}._domainkey.$DOMAIN  ${DKIM_3}.dkim.amazonses.com"
  echo "  TXT   _dmarc.$DOMAIN              \"v=DMARC1; p=none; rua=mailto:dmarc@$DOMAIN\""
  if [[ -n "$VM_IP" ]]; then
    echo "  A     $NEWSLETTER_SUBDOMAIN        $VM_IP"
  fi
fi

echo ""
echo "  GHOST SMTP SETTINGS (add to config.production.json):"
echo "  SMTP Host : email-smtp.${SES_REGION}.amazonaws.com"
echo "  SMTP Port : 587"
echo "  SMTP User : $ACCESS_KEY_ID"
echo "  SMTP Pass : (see deploy/.ses-credentials)"
echo "  From      : newsletter@$DOMAIN"
echo ""
echo "  SES SANDBOX REMOVAL:"
echo "  By default SES is in sandbox — you can only send to verified emails."
echo "  To request production access:"
echo "  1. Go to: https://console.aws.amazon.com/ses/home?region=${SES_REGION}#/account"
echo "  2. Click 'Request production access'"
echo "  3. Use case: Transactional email + newsletter"
echo "  4. Expected volume: ~1,000 emails/day to start"
echo "  5. Describe your opt-in process (Ghost membership signup)"
echo "  Approval typically takes 1-2 business days."
echo "============================================================"
