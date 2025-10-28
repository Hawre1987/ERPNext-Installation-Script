#!/bin/bash

set -euo pipefail

echo "======================================================"
echo " ERPNext v15 Installer for Debian/Ubuntu (Bookworm/Trixie/Noble)  "
echo "======================================================"
echo ""

# === Section 1: Collect Inputs ===
read -rp "Enter Frappe system user (default: frappe): " FRAPPE_USER
FRAPPE_USER=${FRAPPE_USER:-frappe}

read -rsp "Enter password for user $FRAPPE_USER: " FRAPPE_PASS
echo ""
read -rp "Enter ERPNext site name (e.g. erp.mydomain.com): " SITE_NAME
echo ""
read -rsp "Set Administrator password for site $SITE_NAME: " ADMIN_PASS
echo ""

# === Section 2: Install System Dependencies ===
echo "📦 Installing system packages (Node, Redis, Nginx, Ansible, etc)..."
sudo apt update
sudo apt install -y \
  git curl wget python3-dev python3-pip python3-setuptools \
  python3-venv build-essential \
  redis-server mariadb-server mariadb-client \
  libmariadb-dev libmariadb-dev-compat \
  xvfb libfontconfig1 libxrender1 libxext6 \
  cron nodejs npm supervisor nginx ansible \
  fontconfig libfreetype6 libjpeg62-turbo \
  libx11-6 libxcb1

# Install wkhtmltopdf from official source
echo "📥 Downloading and installing wkhtmltopdf..."

# Detect OS version
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_CODENAME=$VERSION_CODENAME
else
    OS_CODENAME="bookworm"
fi

echo "Detected OS: $OS_CODENAME"

# Set appropriate download URL based on OS
case $OS_CODENAME in
    bookworm|trixie)
        WKHTML_URL="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.bookworm_amd64.deb"
        ;;
    bullseye)
        WKHTML_URL="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.bullseye_amd64.deb"
        ;;
    noble)
        # Ubuntu 24.04 - use bookworm version and create symlink
        WKHTML_URL="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.bookworm_amd64.deb"
        ;;
    jammy)
        # Create symlink for libjpeg-turbo8
        sudo ln -sf /usr/lib/x86_64-linux-gnu/libjpeg.so.62 /usr/lib/x86_64-linux-gnu/libjpeg.so.8 2>/dev/null || true
        WKHTML_URL="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.jammy_amd64.deb"
        ;;
    focal)
        WKHTML_URL="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.focal_amd64.deb"
        ;;
    *)
        echo "⚠️  Unknown OS version, trying Bookworm package..."
        WKHTML_URL="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.bookworm_amd64.deb"
        ;;
esac

wget -q $WKHTML_URL -O /tmp/wkhtmltox.deb

# Try to install, if it fails due to dependencies, create symlink and retry
if ! sudo apt install -y /tmp/wkhtmltox.deb 2>/dev/null; then
    echo "⚠️  Dependency issue detected, creating libjpeg symlink..."
    sudo ln -sf /usr/lib/x86_64-linux-gnu/libjpeg.so.62 /usr/lib/x86_64-linux-gnu/libjpeg.so.8
    sudo apt install -y /tmp/wkhtmltox.deb
fi

rm /tmp/wkhtmltox.deb

# === Section 3: Create Frappe User ===
echo "👤 Creating user: $FRAPPE_USER"
if id "$FRAPPE_USER" &>/dev/null; then
  echo "⚠️  User $FRAPPE_USER already exists. Skipping creation."
else
  sudo useradd -m -s /bin/bash "$FRAPPE_USER"
  echo "$FRAPPE_USER:$FRAPPE_PASS" | sudo chpasswd
  sudo usermod -aG sudo "$FRAPPE_USER"
fi

# === Section 4: Node.js & Yarn ===
echo "🔧 Installing Node.js LTS and Yarn..."
sudo npm install -g n
sudo n lts
export PATH="/usr/local/bin:$PATH"
hash -r
sudo npm install -g yarn

# === Section 5: MariaDB Secure Setup ===
echo "🔐 Launching interactive MariaDB secure installation..."
read -rp "Press Enter to continue..."
sudo mysql_secure_installation

read -rsp "🔑 Re-enter the MariaDB root password (used above): " MYSQL_ROOT_PASSWORD
echo ""
echo "🔁 Enforcing password login for MariaDB root..."
sudo mysql -u root <<EOF
SET PASSWORD FOR 'root'@'localhost' = PASSWORD('${MYSQL_ROOT_PASSWORD}');
FLUSH PRIVILEGES;
EOF

# === Section 6: Install Bench CLI ===
echo "🧱 Installing Frappe Bench CLI..."
sudo pip3 install frappe-bench --break-system-packages

# === Section 7: Initialize Frappe Bench ===
echo "📁 Creating /home/$FRAPPE_USER/frappe-bench"
sudo -u "$FRAPPE_USER" -H bash -c "
cd /home/$FRAPPE_USER
bench init frappe-bench --frappe-branch version-15
"

# Ensure nginx can access bench directory
sudo chmod -R o+rx /home/$FRAPPE_USER

# === Section 8: Create Frappe Site ===
echo "🌐 Creating site: $SITE_NAME"
sudo -u "$FRAPPE_USER" -H bash -c "
cd /home/$FRAPPE_USER/frappe-bench
bench new-site $SITE_NAME \
  --mariadb-root-password '$MYSQL_ROOT_PASSWORD' \
  --admin-password '$ADMIN_PASS'
"

# === Section 9: Install ERPNext and Payments ===
echo "📦 Installing ERPNext and Payments apps..."
sudo -u "$FRAPPE_USER" -H bash -c "
cd /home/$FRAPPE_USER/frappe-bench
bench get-app erpnext --branch version-15
bench --site $SITE_NAME install-app erpnext
bench get-app payments --branch version-15
bench --site $SITE_NAME install-app payments
"

# === Section 10: Setup Production (Supervisor, Redis, Nginx) ===
echo "⚙️ Setting up production environment..."

# Generate and copy Supervisor config
echo "📄 Copying Supervisor config..."
sudo -u "$FRAPPE_USER" -H bash -c "
cd /home/$FRAPPE_USER/frappe-bench
bench setup supervisor
"
sudo cp /home/$FRAPPE_USER/frappe-bench/config/supervisor.conf /etc/supervisor/conf.d/frappe.conf
sudo systemctl restart supervisor

# Generate and copy Nginx config
echo "🌐 Configuring Nginx for Frappe site..."
sudo -u "$FRAPPE_USER" -H bash -c "
cd /home/$FRAPPE_USER/frappe-bench
bench setup nginx
"
sudo cp /home/$FRAPPE_USER/frappe-bench/config/nginx.conf /etc/nginx/conf.d/frappe.conf

# Patch access_log format if needed
sudo sed -i 's/access_log\s\+\/var\/log\/nginx\/access\.log\s\+main;/access_log \/var\/log\/nginx\/access.log combined;/' /etc/nginx/conf.d/frappe.conf

# Remove default Nginx site to avoid welcome page
sudo rm -f /etc/nginx/sites-enabled/default

sudo nginx -t && sudo systemctl reload nginx

# Setup production inside frappe-bench folder
sudo -u "$FRAPPE_USER" -H bash -c "
cd /home/$FRAPPE_USER/frappe-bench
bench setup production $FRAPPE_USER
"

# Reload Supervisor
sudo supervisorctl reread
sudo supervisorctl update
sudo supervisorctl restart all

# === Section 11: Install HRMS ===
echo "📦 Installing HRMS app..."
sudo -u "$FRAPPE_USER" -H bash -c "
cd /home/$FRAPPE_USER/frappe-bench
bench get-app hrms --branch version-15
bench --site $SITE_NAME install-app hrms
"
# === Section 12: Restart Services ===
echo "🔄 Restarting all services..."
sudo supervisorctl restart all
sudo systemctl reload nginx

# === Section 13: Done ===
echo ""
echo "✅ ERPNext v15, Payments, HRMS installed successfully!"
echo "🌐 Access your site at: http://localhost or http://$SITE_NAME"
echo "👤 Administrator password you set earlier is now active."
echo ""
echo "📋 Installed apps:"
echo "   - ERPNext v15"
echo "   - Payments"
echo "   - HRMS"
echo ""