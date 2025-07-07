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
  git curl python3-dev python3-pip python3-setuptools \
  python3-venv build-essential \
  redis-server mariadb-server mariadb-client \
  libmariadb-dev libmariadb-dev-compat \
  wkhtmltopdf xvfb libfontconfig1 libxrender1 libxext6 \
  cron nodejs npm supervisor nginx ansible

# === Section 3: Create Frappe User ===
echo "👤 Creating user: $FRAPPE_USER"
if id "$FRAPPE_USER" &>/dev/null; then
  echo "⚠️  User $FRAPPE_USER already exists. Skipping creation."
else
  sudo useradd -m -s /bin/bash "$FRAPPE_USER"
  echo "$FRAPPE_USER:$FRAPPE_PASS" | sudo chpasswd
  sudo usermod -aG sudo "$FRAPPE_USER"
fi

# === Section 3.1: Setup SSH key for $FRAPPE_USER ===
echo "🔐 Setting up SSH access for $FRAPPE_USER..."
sudo -u "$FRAPPE_USER" -H bash -c "
mkdir -p /home/$FRAPPE_USER/.ssh
chmod 700 /home/$FRAPPE_USER/.ssh
"

if [ -f ~/.ssh/id_rsa.pub ]; then
  echo "📅 Copying current user's public key to $FRAPPE_USER"
  sudo cp ~/.ssh/id_rsa.pub /home/$FRAPPE_USER/.ssh/authorized_keys
  sudo chown $FRAPPE_USER:$FRAPPE_USER /home/$FRAPPE_USER/.ssh/authorized_keys
  sudo chmod 600 /home/$FRAPPE_USER/.ssh/authorized_keys
else
  echo "⚠️  No ~/.ssh/id_rsa.pub found on current user. You must manually add keys to /home/$FRAPPE_USER/.ssh/authorized_keys"
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

# Ensure nginx can access bench directory (Moved to line 70)
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

# === Section 12: Done ===
echo ""
echo "✅ ERPNext v15, Payments, and HRMS installed successfully!"
echo "🌐 Access your site at: http://localhost or http://$SITE_NAME"
echo "👤 Administrator password you set earlier is now active."
echo ""
