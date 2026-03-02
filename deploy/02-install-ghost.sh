#!/usr/bin/env bash
# =============================================================================
# 02-install-ghost.sh — Install Ghost CMS stack on Oracle Cloud Ubuntu 22.04
# =============================================================================
# Run this script ON the Oracle VM (copy via scp first):
#
#   scp -i ~/.ssh/ghost-oracle deploy/02-install-ghost.sh ubuntu@<VM_IP>:~/
#   ssh -i ~/.ssh/ghost-oracle ubuntu@<VM_IP> 'bash ~/02-install-ghost.sh'
#
# What this installs:
#   - System updates + dependencies
#   - Node.js 18 LTS (via NodeSource)
#   - Nginx
#   - MySQL 8
#   - Ghost-CLI + Ghost
#   - Certbot (Let's Encrypt SSL)
#   - UFW firewall rules
# =============================================================================

set -euo pipefail

GHOST_DOMAIN="newsletter.dolphinwebdynamics.com"
GHOST_DIR="/var/www/ghost"
GHOST_USER="ghost-user"
GHOST_DB_NAME="ghost_production"
GHOST_DB_USER="ghost"
GHOST_DB_PASS="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 32)"
ADMIN_EMAIL="anel@dolphinwebdynamics.com"

echo "==> Installing Ghost on $GHOST_DOMAIN"

# ---------------------------------------------------------------------------
# 1. System update + dependencies
# ---------------------------------------------------------------------------
echo "==> Updating system..."
sudo apt-get update -y
sudo apt-get upgrade -y
sudo apt-get install -y \
  curl wget gnupg2 software-properties-common \
  apt-transport-https ca-certificates lsb-release \
  unzip git build-essential ufw fail2ban

# ---------------------------------------------------------------------------
# 2. Node.js 18 LTS
# ---------------------------------------------------------------------------
echo "==> Installing Node.js 18 LTS..."
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y nodejs
node --version
npm --version

# ---------------------------------------------------------------------------
# 3. Nginx
# ---------------------------------------------------------------------------
echo "==> Installing Nginx..."
sudo apt-get install -y nginx
sudo systemctl enable nginx
sudo systemctl start nginx

# ---------------------------------------------------------------------------
# 4. MySQL 8
# ---------------------------------------------------------------------------
echo "==> Installing MySQL 8..."
sudo apt-get install -y mysql-server
sudo systemctl enable mysql
sudo systemctl start mysql

# Secure MySQL and create Ghost database
sudo mysql -e "
  ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '';
  CREATE DATABASE IF NOT EXISTS \`${GHOST_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
  CREATE USER IF NOT EXISTS '${GHOST_DB_USER}'@'localhost' IDENTIFIED BY '${GHOST_DB_PASS}';
  GRANT ALL PRIVILEGES ON \`${GHOST_DB_NAME}\`.* TO '${GHOST_DB_USER}'@'localhost';
  FLUSH PRIVILEGES;
"
echo "    MySQL: database '${GHOST_DB_NAME}' and user '${GHOST_DB_USER}' created"

# Save DB password to a local file (chmod 600)
echo "${GHOST_DB_PASS}" | sudo tee /root/.ghost-db-password > /dev/null
sudo chmod 600 /root/.ghost-db-password
echo "    DB password saved to /root/.ghost-db-password"

# ---------------------------------------------------------------------------
# 5. Ghost-CLI
# ---------------------------------------------------------------------------
echo "==> Installing Ghost-CLI..."
sudo npm install -g ghost-cli@latest

# ---------------------------------------------------------------------------
# 6. Create ghost system user
# ---------------------------------------------------------------------------
echo "==> Creating ghost system user: $GHOST_USER"
if ! id "$GHOST_USER" &>/dev/null; then
  sudo adduser --shell /bin/bash --gecos "Ghost User" --disabled-password "$GHOST_USER"
fi
sudo usermod -aG sudo "$GHOST_USER"

# ---------------------------------------------------------------------------
# 7. Prepare Ghost install directory
# ---------------------------------------------------------------------------
echo "==> Preparing $GHOST_DIR..."
sudo mkdir -p "$GHOST_DIR"
sudo chown "$GHOST_USER":"$GHOST_USER" "$GHOST_DIR"
sudo chmod 775 "$GHOST_DIR"

# ---------------------------------------------------------------------------
# 8. Install Ghost (non-interactive, skip SSL — we handle SSL separately)
# ---------------------------------------------------------------------------
echo "==> Installing Ghost CMS (this takes ~5 minutes)..."
sudo -u "$GHOST_USER" ghost install \
  --dir "$GHOST_DIR" \
  --url "https://${GHOST_DOMAIN}" \
  --db mysql \
  --dbhost localhost \
  --dbname "$GHOST_DB_NAME" \
  --dbuser "$GHOST_DB_USER" \
  --dbpass "$GHOST_DB_PASS" \
  --process systemd \
  --no-prompt \
  --no-setup-ssl \
  --no-setup-nginx \
  --no-start

# ---------------------------------------------------------------------------
# 9. Copy production config (if it exists from scp)
# ---------------------------------------------------------------------------
if [[ -f ~/config.production.json ]]; then
  echo "==> Applying production config..."
  sudo cp ~/config.production.json "${GHOST_DIR}/config.production.json"
  sudo chown "$GHOST_USER":"$GHOST_USER" "${GHOST_DIR}/config.production.json"
  sudo chmod 600 "${GHOST_DIR}/config.production.json"
fi

# ---------------------------------------------------------------------------
# 10. Nginx config for Ghost
# ---------------------------------------------------------------------------
echo "==> Configuring Nginx..."
sudo tee /etc/nginx/sites-available/ghost << 'NGINX_CONF'
server {
    listen 80;
    listen [::]:80;
    server_name newsletter.dolphinwebdynamics.com;

    # Redirect HTTP → HTTPS (after cert is issued)
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name newsletter.dolphinwebdynamics.com;

    # SSL — managed by Certbot
    ssl_certificate     /etc/letsencrypt/live/newsletter.dolphinwebdynamics.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/newsletter.dolphinwebdynamics.com/privkey.pem;
    include             /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam         /etc/letsencrypt/ssl-dhparams.pem;

    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options           "SAMEORIGIN"                          always;
    add_header X-Content-Type-Options    "nosniff"                             always;
    add_header X-XSS-Protection          "1; mode=block"                       always;
    add_header Referrer-Policy           "no-referrer-when-downgrade"          always;

    client_max_body_size 50m;

    location / {
        proxy_pass             http://127.0.0.1:2368;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_buffering    off;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade    $http_upgrade;
        proxy_set_header   Connection "upgrade";
    }
}
NGINX_CONF

sudo ln -sf /etc/nginx/sites-available/ghost /etc/nginx/sites-enabled/ghost
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t

# Temporarily serve on HTTP for Certbot validation
sudo tee /etc/nginx/sites-available/ghost-temp << 'NGINX_TEMP'
server {
    listen 80;
    listen [::]:80;
    server_name newsletter.dolphinwebdynamics.com;
    root /var/www/html;
    location / { try_files $uri $uri/ =404; }
}
NGINX_TEMP

sudo ln -sf /etc/nginx/sites-available/ghost-temp /etc/nginx/sites-enabled/ghost-temp
sudo rm -f /etc/nginx/sites-enabled/ghost
sudo nginx -t && sudo systemctl reload nginx

# ---------------------------------------------------------------------------
# 11. Certbot + Let's Encrypt SSL
# ---------------------------------------------------------------------------
echo "==> Installing Certbot..."
sudo apt-get install -y certbot python3-certbot-nginx

echo "==> Provisioning SSL certificate for $GHOST_DOMAIN"
echo "    (DNS A record must already point to this server's IP)"
sudo certbot --nginx \
  -d "$GHOST_DOMAIN" \
  --non-interactive \
  --agree-tos \
  --email "$ADMIN_EMAIL" \
  --redirect

# Swap back to full Nginx config with SSL
sudo ln -sf /etc/nginx/sites-available/ghost /etc/nginx/sites-enabled/ghost
sudo rm -f /etc/nginx/sites-enabled/ghost-temp
sudo nginx -t && sudo systemctl reload nginx

# ---------------------------------------------------------------------------
# 12. UFW Firewall
# ---------------------------------------------------------------------------
echo "==> Configuring UFW firewall..."
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp   comment "SSH"
sudo ufw allow 80/tcp   comment "HTTP"
sudo ufw allow 443/tcp  comment "HTTPS"
sudo ufw --force enable
sudo ufw status verbose

# ---------------------------------------------------------------------------
# 13. Start Ghost
# ---------------------------------------------------------------------------
echo "==> Starting Ghost..."
cd "$GHOST_DIR"
sudo -u "$GHOST_USER" ghost start

# ---------------------------------------------------------------------------
# 14. Backup cron (daily mysqldump at 2am)
# ---------------------------------------------------------------------------
echo "==> Setting up database backup cron..."
sudo tee /usr/local/bin/ghost-backup.sh << 'BACKUP'
#!/usr/bin/env bash
BACKUP_DIR="/var/backups/ghost"
DATE=$(date +%Y%m%d-%H%M%S)
mkdir -p "$BACKUP_DIR"
mysqldump ghost_production | gzip > "$BACKUP_DIR/ghost_production_${DATE}.sql.gz"
# Keep last 14 backups
find "$BACKUP_DIR" -name "*.sql.gz" -mtime +14 -delete
BACKUP

sudo chmod +x /usr/local/bin/ghost-backup.sh
(sudo crontab -l 2>/dev/null; echo "0 2 * * * /usr/local/bin/ghost-backup.sh") | sudo crontab -

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  GHOST INSTALLATION COMPLETE"
echo "============================================================"
echo "  Ghost URL   : https://$GHOST_DOMAIN"
echo "  Ghost Admin : https://$GHOST_DOMAIN/ghost/"
echo "  Ghost Dir   : $GHOST_DIR"
echo "  DB Name     : $GHOST_DB_NAME"
echo "  DB User     : $GHOST_DB_USER"
echo "  DB Password : $(sudo cat /root/.ghost-db-password)"
echo ""
echo "  Next steps:"
echo "  1. Visit https://$GHOST_DOMAIN/ghost/ to create your admin account"
echo "  2. Configure SES email — run deploy/03-setup-ses.sh locally"
echo "  3. Update config.production.json with SES SMTP credentials"
echo "  4. Connect Stripe in Ghost Admin → Settings → Memberships"
echo "============================================================"
