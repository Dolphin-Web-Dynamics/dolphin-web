# Dolphin Web Dynamics — Ghost Newsletter + Agency Site

Two-site architecture for Dolphin Web Dynamics:

| Site | URL | Stack |
|------|-----|-------|
| Agency site | `dolphinwebdynamics.com` | React/Vite → Vercel |
| Newsletter/blog/memberships | `newsletter.dolphinwebdynamics.com` | Ghost → Google Cloud Compute Engine |

---

## Prerequisites

Before running any scripts, verify you have:

- [ ] **gcloud CLI** — `gcloud --version` (authenticated: `gcloud auth login`, project: `dolphin-vertex-ai`)
- [ ] **AWS CLI** — `aws --version` (configured with your IAM credentials, for Route 53)
- [ ] **jq** — `jq --version` (`brew install jq`)
- [ ] **Vercel CLI** — `vercel --version` (`npm install -g vercel`)
- [ ] **Node.js 18+** on your local machine

---

## Execution Order

### Step 1 — Provision GCE VM

```bash
chmod +x deploy/01-provision-gce.sh
./deploy/01-provision-gce.sh
```

This creates:
- Firewall rule `ghost-allow-web` (tcp:22,80,443)
- Static external IP `ghost-newsletter-ip`
- `e2-small` VM (2 vCPU shared, 2GB RAM, ~$14/mo) in `us-central1-a`
- Ubuntu 22.04 LTS, 30GB balanced persistent disk
- Route 53 A record: `newsletter.dolphinwebdynamics.com` → static IP

**Output**: The VM's static public IP is printed and saved to `deploy/.vm-public-ip`.

---

### Step 2 — Configure DNS via Route 53

The `01-provision-gce.sh` script auto-creates the `newsletter` A record in Route 53.
The `03-setup-ses.sh` script creates all SES/DKIM/DMARC records.

**If dolphinwebdynamics.com is already in Route 53**, skip to Step 3.

**Manual DNS records** (if not using scripts):

| Record | Type | Value | TTL |
|--------|------|-------|-----|
| `dolphinwebdynamics.com` | A/ALIAS | Vercel IP (or CNAME to `cname.vercel-dns.com`) | 300 |
| `www.dolphinwebdynamics.com` | CNAME | `cname.vercel-dns.com` | 300 |
| `newsletter.dolphinwebdynamics.com` | A | `<GCE static IP>` | 300 |

> Run `cat deploy/.vm-public-ip` to get the static IP after Step 1.

---

### Step 3 — Set Up Amazon SES Email

```bash
chmod +x deploy/03-setup-ses.sh
./deploy/03-setup-ses.sh
```

This script:
- Verifies your domain in SES (us-east-1)
- Generates DKIM keys
- **Automatically creates Route 53 DNS records** (DKIM CNAMEs, SPF TXT, DMARC TXT, newsletter A record)
- Creates IAM user `ghost-ses-sender` with SMTP credentials
- Saves credentials to `deploy/.ses-credentials` (chmod 600)

**After running**, update `deploy/config.production.json`:
```bash
# Get your SES SMTP credentials
cat deploy/.ses-credentials

# Edit config.production.json — replace the REPLACE_WITH_* placeholders
nano deploy/config.production.json
```

**Request SES production access** (exit sandbox):
1. Go to [SES Account Dashboard](https://console.aws.amazon.com/ses/home?region=us-east-1#/account)
2. Click **Request production access**
3. Use case: Transactional + marketing email
4. Describe opt-in process: "Users subscribe via Ghost membership signup form"
5. Expected volume: 1,000 emails/day to start
6. Approval: typically 1–2 business days

---

### Step 4 — Install Ghost on the VM

```bash
ZONE="us-central1-a"

# Copy install script and config to VM
gcloud compute scp deploy/02-install-ghost.sh ghost-newsletter:~/ --zone=$ZONE
gcloud compute scp deploy/config.production.json ghost-newsletter:~/ --zone=$ZONE

# Run the install script (~10 minutes)
gcloud compute ssh ghost-newsletter --zone=$ZONE -- 'bash ~/02-install-ghost.sh'
```

> **Important**: The DNS A record for `newsletter.dolphinwebdynamics.com` must be propagated before running this script — Certbot needs to verify domain ownership via HTTP.

Check propagation first:
```bash
dig newsletter.dolphinwebdynamics.com A +short
# Should return your GCE static IP
```

---

### Step 5 — Deploy React Site to Vercel

```bash
cd /Users/anelcanto/projects/internet-whisper-check

# First-time deploy
vercel

# Set environment variables (Supabase — if using)
vercel env add VITE_SUPABASE_URL
vercel env add VITE_SUPABASE_ANON_KEY

# Add custom domain in Vercel dashboard:
# Project → Settings → Domains → Add dolphinwebdynamics.com
```

Vercel will display the CNAME/A record to add to Route 53. The `vercel.json` is already configured with:
- Build: `vite build`
- Output: `dist`
- SPA rewrites (React Router support)
- Security headers
- Asset caching (1 year, immutable)

---

## Ghost Admin Setup

After the VM install completes:

1. **Create admin account** — Visit `https://newsletter.dolphinwebdynamics.com/ghost/`
   - Set site title: "Dolphin Web Dynamics · AI Insights"
   - Create your admin user

2. **Configure email sending** — Ghost Admin → Settings → Email newsletter
   - Verify the SES SMTP settings are working: click "Send test email"

3. **Set up membership tiers** — Ghost Admin → Settings → Memberships
   - Free tier: Weekly newsletter access
   - Premium tier ($9–15/mo suggested): Implementation guides + templates + Q&A
   - Connect Stripe: Click "Connect with Stripe" → follow OAuth flow

4. **Install newsletter template** — Ghost Admin → Settings → Email newsletter → Customize
   - The template at `templates/newsletter-weekly.hbs` can be imported or used as reference for Ghost's built-in editor

5. **Configure publication details** — Ghost Admin → Settings → General
   - Publication name, description, icon, cover image
   - Time zone: set to your local timezone

---

## DNS Configuration Reference

Complete DNS records for `dolphinwebdynamics.com`:

| Name | Type | Value | Purpose |
|------|------|-------|---------|
| `dolphinwebdynamics.com` | A/ALIAS | Vercel | Agency site root |
| `www` | CNAME | `cname.vercel-dns.com` | Agency site www |
| `newsletter` | A | `<GCE static IP>` | Ghost newsletter |
| `_amazonses` | TXT | `<token from SES>` | SES domain verification |
| `<token1>._domainkey` | CNAME | `<token1>.dkim.amazonses.com` | DKIM email signing |
| `<token2>._domainkey` | CNAME | `<token2>.dkim.amazonses.com` | DKIM email signing |
| `<token3>._domainkey` | CNAME | `<token3>.dkim.amazonses.com` | DKIM email signing |
| `_dmarc` | TXT | `v=DMARC1; p=none; rua=mailto:dmarc@dolphinwebdynamics.com` | DMARC policy |

All Route 53 records are created automatically by `03-setup-ses.sh` and `01-provision-gce.sh`.

---

## Backup Strategy

Daily MySQL backups are configured automatically by `02-install-ghost.sh`:

```
Cron: 0 2 * * * /usr/local/bin/ghost-backup.sh
Location: /var/backups/ghost/
Retention: 14 days
Format: ghost_production_YYYYMMDD-HHMMSS.sql.gz
```

**Ghost content export** (posts, settings, members):
- Ghost Admin → Settings → Labs → Export your content
- Download JSON export monthly and store in a safe location

**Manual backup commands**:
```bash
gcloud compute ssh ghost-newsletter --zone=us-central1-a
  sudo /usr/local/bin/ghost-backup.sh
  ls -la /var/backups/ghost/
```

---

## Verification Checklist

After completing all steps:

- [ ] `gcloud compute ssh ghost-newsletter --zone=us-central1-a` — SSH works
- [ ] `https://newsletter.dolphinwebdynamics.com` — Ghost site loads, SSL padlock shows
- [ ] `https://newsletter.dolphinwebdynamics.com/ghost/` — Ghost admin login works
- [ ] Ghost Admin → Settings → Email → Send test email arrives in inbox
- [ ] `https://dolphinwebdynamics.com` — Agency site loads on Vercel
- [ ] Both sites show valid Let's Encrypt / Vercel SSL certificates
- [ ] Stripe connected in Ghost Admin → Settings → Memberships
- [ ] Subscribe with a test email → confirm welcome email arrives

---

## Troubleshooting

### Ghost won't start
```bash
gcloud compute ssh ghost-newsletter --zone=us-central1-a
cd /var/www/ghost
sudo -u ghost-user ghost status
sudo -u ghost-user ghost log
journalctl -u ghost_newsletter-dolphinwebdynamics-com -n 50
```

### SSL certificate fails
```bash
# Check DNS propagation
dig newsletter.dolphinwebdynamics.com A +short

# Re-run Certbot manually
sudo certbot --nginx -d newsletter.dolphinwebdynamics.com --reinstall
```

### Nginx 502 Bad Gateway
```bash
# Check if Ghost is running
sudo -u ghost-user ghost status
# Restart Ghost
sudo -u ghost-user ghost restart
# Check Nginx
sudo nginx -t
sudo systemctl reload nginx
```

### SES emails going to spam
1. Verify DKIM records are propagated: `dig <token1>._domainkey.dolphinwebdynamics.com CNAME +short`
2. Check DMARC: `dig _dmarc.dolphinwebdynamics.com TXT +short`
3. Test with [mail-tester.com](https://www.mail-tester.com) — send a test email, get a score
4. Ensure SES production access has been approved (out of sandbox)

### VM out of memory
The e2-small with 2GB RAM is sufficient for Ghost + MySQL + Nginx. Add swap if needed:
```bash
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

---

## File Structure

```
dolphin-web/
├── README.md                        # This file
├── deploy/
│   ├── 01-provision-gce.sh          # gcloud: create VM + firewall + static IP + DNS
│   ├── 02-install-ghost.sh          # Ghost stack installer (runs on VM via gcloud ssh)
│   ├── 03-setup-ses.sh              # AWS SES + Route 53 DNS setup
│   ├── config.production.json       # Ghost production config (edit before deploying)
│   ├── nginx-ghost.conf             # Nginx reverse proxy config (reference)
│   ├── .vm-public-ip                # Auto-generated: GCE static IP
│   └── .ses-credentials             # Auto-generated: SES SMTP credentials (SECRET)
└── templates/
    └── newsletter-weekly.hbs        # Ghost email template

# Separate project:
internet-whisper-check/
└── vercel.json                      # Vercel deployment config
```

> **Security note**: `deploy/.ses-credentials` and `deploy/.vm-public-ip` are gitignored. Verify `.gitignore` contains:
> ```
> deploy/.ses-credentials
> deploy/.vm-public-ip
> ```
