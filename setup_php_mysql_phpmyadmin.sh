#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────
_wait_for_apt() {
  local lock=/var/lib/dpkg/lock-frontend max=300 waited=0
  while sudo fuser "$lock" &>/dev/null 2>&1; do
    echo "→ Waiting for apt lock..."
    sleep 3; waited=$((waited+3))
    [ "$waited" -ge "$max" ] && { echo "⛔ apt lock timeout" >&2; exit 1; }
  done
}

_installed() { dpkg -s "$1" &>/dev/null; }

_install() {
  local pkg="$1"
  if _installed "$pkg"; then
    echo "→ Skipping $pkg"
  else
    _wait_for_apt
    echo "→ Installing $pkg"
    sudo apt install -y --no-install-recommends "$pkg"
  fi
}

_add_php_ppa() {
  if grep -Rq '^deb .\+ondrej/php' /etc/apt/sources.list.d; then
    echo "→ PHP PPA exists"
  else
    _wait_for_apt
    echo "→ Adding Ondřej Surý’s PHP PPA"
    sudo add-apt-repository ppa:ondrej/php -y
    _wait_for_apt; sudo apt update
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 1) Purge Apache if present
# ──────────────────────────────────────────────────────────────────────────────
echo "→ Removing Apache if present"
if dpkg -l | grep -E 'apache2|libapache2-mod-' &>/dev/null; then
  sudo apt purge --auto-remove -y apache2* libapache2-mod-*
fi

# ──────────────────────────────────────────────────────────────────────────────
# 2) Update & prerequisites
# ──────────────────────────────────────────────────────────────────────────────
_wait_for_apt; echo "→ apt update"; sudo apt update
echo "→ apt upgrade"; _wait_for_apt; sudo apt upgrade -y
for pkg in software-properties-common lsb-release ca-certificates apt-transport-https openssl wget tar; do
  _install "$pkg"
done

# ──────────────────────────────────────────────────────────────────────────────
# 3) PHP PPA & Nginx
# ──────────────────────────────────────────────────────────────────────────────
_add_php_ppa
_install nginx
sudo systemctl enable --now nginx

# ──────────────────────────────────────────────────────────────────────────────
# 4) MySQL & root password
# ──────────────────────────────────────────────────────────────────────────────
_install mysql-server
MYSQL_ROOT_PASS=$(openssl rand -hex 16)
echo "→ Setting MySQL root password"
sudo mysql <<SQL
ALTER USER 'root'@'localhost'
  IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASS}';
FLUSH PRIVILEGES;
SQL
echo "→ Starting MySQL"
sudo systemctl start mysql

# ──────────────────────────────────────────────────────────────────────────────
# 5) PHP 8.1–8.4 & Laravel extensions
# ──────────────────────────────────────────────────────────────────────────────
PHP_VERSIONS=(8.1 8.2 8.3 8.4)
EXTS=(fpm cli mysql mbstring curl xml zip gd opcache bcmath intl)

for ver in "${PHP_VERSIONS[@]}"; do
  echo "→ Installing PHP ${ver} and extensions"
  _install php"${ver}"-fpm
  _install php"${ver}"-cli
  for ext in "${EXTS[@]}"; do
    _install php"${ver}"-"${ext}"
  done
  sudo systemctl enable --now php"${ver}"-fpm
done

# ──────────────────────────────────────────────────────────────────────────────
# 6) Install phpMyAdmin via APT
# ──────────────────────────────────────────────────────────────────────────────
echo "→ Installing phpMyAdmin + PHP extensions"
export DEBIAN_FRONTEND=noninteractive
sudo apt update
sudo apt install -y phpmyadmin php-mbstring php-zip php-gd

# ──────────────────────────────────────────────────────────────────────────────
# 7) Nginx config for phpMyAdmin
# ──────────────────────────────────────────────────────────────────────────────
NGINX_CONF=/etc/nginx/sites-available/default
echo "→ Adding phpMyAdmin location block to $NGINX_CONF"
sudo tee -a "$NGINX_CONF" > /dev/null <<'EOF'

    # phpMyAdmin
    location /phpmyadmin {
        alias /usr/share/phpmyadmin/;
        index index.php index.html;
    }

    location ~ ^/phpmyadmin/(.+\.php)$ {
        alias /usr/share/phpmyadmin/$1;
        fastcgi_pass unix:/run/php/php8.4-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME /usr/share/phpmyadmin/$1;
    }

    location ~* ^/phpmyadmin/(.+\.(css|js|png|jpg|jpeg|gif|ico))$ {
        alias /usr/share/phpmyadmin/$1;
    }
EOF

# ──────────────────────────────────────────────────────────────────────────────
# 8) Test & reload Nginx + final summary
# ──────────────────────────────────────────────────────────────────────────────
echo "→ Testing Nginx configuration"
sudo nginx -t

echo "→ Reloading Nginx"
sudo systemctl reload nginx

IP=$(hostname -I | awk '{print $1}')
cat <<EOF

✅ Setup Complete!

• phpMyAdmin → http://${IP}/phpmyadmin
• MySQL root   → root / ${MYSQL_ROOT_PASS}
• PHP versions → ${PHP_VERSIONS[*]}
• Extensions   → ${EXTS[*]}

Your pure LEMP server is ready for Laravel.
EOF
