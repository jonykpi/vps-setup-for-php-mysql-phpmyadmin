#!/usr/bin/env bash
set -euo pipefail

# 
──────────────────────────────────────────────────────────────────────────────
# Utility functions
# 
──────────────────────────────────────────────────────────────────────────────
is_installed() {
  dpkg -s "$1" &>/dev/null
}

install_pkg() {
  pkg="$1"
  if is_installed "$pkg"; then
    echo "→ Skipping ${pkg}, already installed."
  else
    echo "→ Installing ${pkg}…"
    sudo apt install -y "$pkg"
  fi
}

add_php_ppa() {
  if grep -Rqs "^deb .\+ondrej/php" /etc/apt/sources.list.d; then
    echo "→ PHP PPA already present, skipping."
  else
    echo "→ Adding Ondřej Surý’s PHP PPA…"
    sudo add-apt-repository ppa:ondrej/php -y
    sudo apt update
  fi
}

reinstall_mysql() {
  echo "→ Reinstalling MySQL Server…"
  sudo apt remove -y --purge mysql-server mysql-client mysql-common
  sudo apt autoremove -y
  sudo apt install -y mysql-server
}

# 
──────────────────────────────────────────────────────────────────────────────
# 1) Update & prerequisites
# 
──────────────────────────────────────────────────────────────────────────────
echo "→ Updating apt…"
sudo apt update
echo "→ Upgrading packages…"
sudo apt upgrade -y

PREREQS=(software-properties-common lsb-release ca-certificates apt-transport-https openssl)
for pkg in "${PREREQS[@]}"; do
  install_pkg "$pkg"
done

# 
──────────────────────────────────────────────────────────────────────────────
# 2) Add PHP PPA
# 
──────────────────────────────────────────────────────────────────────────────
add_php_ppa

# 
──────────────────────────────────────────────────────────────────────────────
# 3) Install Nginx
# 
──────────────────────────────────────────────────────────────────────────────
install_pkg nginx
sudo systemctl enable --now nginx

# 
──────────────────────────────────────────────────────────────────────────────
# 4) Install & configure MySQL root
# 
──────────────────────────────────────────────────────────────────────────────
if is_installed mysql-server; then
  echo "→ MySQL already installed, skipping install."
else
  echo "→ Installing MySQL Server…"
  sudo apt install -y mysql-server
fi

# generate a strong random password (32 hex chars)
MYSQL_ROOT_PASS=$(openssl rand -hex 16)

echo "→ Configuring MySQL root user…"
if sudo mysql <<EOF
ALTER USER 'root'@'localhost'
  IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASS}';
FLUSH PRIVILEGES;
EOF
then
  echo "→ MySQL root password set."
else
  echo "⚠️  Failed to set MySQL root password. Reinstalling MySQL and retrying…"
  reinstall_mysql
  # regenerate password after fresh install
  MYSQL_ROOT_PASS=$(openssl rand -hex 16)
  sudo mysql <<EOF
ALTER USER 'root'@'localhost'
  IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASS}';
FLUSH PRIVILEGES;
EOF
  echo "→ MySQL root password set after reinstall."
fi

# 
──────────────────────────────────────────────────────────────────────────────
# 5) Install PHP 8.1–8.4 & Laravel extensions
# 
──────────────────────────────────────────────────────────────────────────────
PHP_VERSIONS=(8.1 8.2 8.3 8.4)
EXTS=(fpm cli mysql mbstring curl xml zip gd opcache bcmath intl tokenizer fileinfo)

for ver in "${PHP_VERSIONS[@]}"; do
  echo "→ Processing PHP ${ver}…"
  install_pkg "php${ver}"
  for ext in "${EXTS[@]}"; do
    install_pkg "php${ver}-${ext}"
  done
  sudo systemctl enable --now "php${ver}-fpm"
done

# 
──────────────────────────────────────────────────────────────────────────────
# 6) Install phpMyAdmin (no internal DB setup)
# 
──────────────────────────────────────────────────────────────────────────────
if is_installed phpmyadmin; then
  echo "→ phpMyAdmin already installed, skipping."
else
  echo "→ Installing phpMyAdmin…"
  sudo debconf-set-selections <<DEB
phpmyadmin phpmyadmin/dbconfig-install boolean false
DEB
  export DEBIAN_FRONTEND=noninteractive
  sudo apt install -y phpmyadmin
fi

# 
──────────────────────────────────────────────────────────────────────────────
# 7) Configure Nginx alias for /db (phpMyAdmin)
# 
──────────────────────────────────────────────────────────────────────────────
NGINX_DEFAULT="/etc/nginx/sites-available/default"
if grep -q "location /db/" "$NGINX_DEFAULT"; then
  echo "→ Nginx alias for /db already configured, skipping."
else
  echo "→ Adding Nginx alias for /db…"
  sudo sed -i '/server_name _;/a \
    # phpMyAdmin alias\n\
    location /db/ {\n\
        alias /usr/share/phpmyadmin/;\n\
        index index.php index.html;\n\
    }\n\
    location ~ ^/db/(.+\.php)$ {\n\
        alias /usr/share/phpmyadmin/$1;\n\
        include fastcgi_params;\n\
        fastcgi_param SCRIPT_FILENAME /usr/share/phpmyadmin/$1;\n\
        fastcgi_pass unix:/run/php/php8.1-fpm.sock;\n\
    }\n' "$NGINX_DEFAULT"
fi

# 
──────────────────────────────────────────────────────────────────────────────
# 8) Restart Nginx
# 
──────────────────────────────────────────────────────────────────────────────
echo "→ Testing Nginx configuration…"
sudo nginx -t
echo "→ Restarting Nginx…"
sudo systemctl restart nginx

# 
──────────────────────────────────────────────────────────────────────────────
# 9) Final summary
# 
──────────────────────────────────────────────────────────────────────────────
IP_ADDR=$(hostname -I | awk '{print $1}')

cat <<EOF

✅ Setup complete!

🔗 phpMyAdmin is available at:
    http://${IP_ADDR}/db

👤 MySQL root credentials:
    username: root
    password: ${MYSQL_ROOT_PASS}

📦 PHP versions installed:
    • ${PHP_VERSIONS[*]}
📦 Extensions installed for each:
    • ${EXTS[*]}

If setting the MySQL root password fails initially, the script reinstalls MySQL and retries. Subsequent runs will skip 
already-installed components.
EOF

