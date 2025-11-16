#!/usr/bin/env bash
set -e

##############################################
# CONFIG (EDIT THESE BEFORE RUNNING)
##############################################

MAGENTO_DOMAIN="yourdomain.com"
MAGENTO_DIR="/var/www/magento"
DB_NAME="magento"
DB_USER="magento"
DB_PASS="StrongPassword123"
ADMIN_FIRSTNAME="Admin"
ADMIN_LASTNAME="User"
ADMIN_EMAIL="admin@yourdomain.com"
ADMIN_USER="admin"
ADMIN_PASS="Admin123!"

##############################################
# START INSTALLATION
##############################################

echo "=== Updating system ==="
apt update && apt upgrade -y

echo "=== Installing base packages ==="
apt install -y software-properties-common curl unzip wget git

##############################################
# PHP 8.2 + required extensions
##############################################

echo "=== Installing PHP 8.2 ==="
add-apt-repository ppa:ondrej/php -y
apt update
apt install -y php8.2 php8.2-fpm php8.2-cli php8.2-curl php8.2-mysql php8.2-gd \
php8.2-zip php8.2-intl php8.2-mbstring php8.2-xml php8.2-bcmath php8.2-soap \
php8.2-xsl php8.2-opcache php8.2-readline

##############################################
# NGINX
##############################################

echo "=== Installing Nginx ==="
apt install -y nginx

##############################################
# MySQL (or MariaDB)
##############################################

echo "=== Installing MySQL ==="
apt install -y mysql-server

echo "=== Creating Magento DB and user ==="

mysql <<EOF
CREATE DATABASE IF NOT EXISTS $DB_NAME;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

##############################################
# Elasticsearch / OpenSearch
##############################################

echo "=== Installing OpenSearch 2.x ==="
wget https://artifacts.opensearch.org/releases/bundle/opensearch/2.11.1/opensearch-2.11.1-linux-x64.tar.gz
tar -xzf opensearch*.tar.gz -C /opt
mv /opt/opensearch-* /opt/opensearch

# Systemd service
cat >/etc/systemd/system/opensearch.service <<EOL
[Unit]
Description=OpenSearch
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
Group=root
ExecStart=/opt/opensearch/bin/opensearch
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOL

systemctl daemon-reload
systemctl enable opensearch
systemctl start opensearch

##############################################
# Composer
##############################################

echo "=== Installing Composer ==="
curl -sS https://getcomposer.org/installer | php
mv composer.phar /usr/local/bin/composer

##############################################
# Magento Download & Install
##############################################

echo "=== Setting up Magento directory ==="
mkdir -p $MAGENTO_DIR
cd $MAGENTO_DIR

# Use Magento repo (requires Auth keys; replace if needed)
echo "=== Downloading Magento (Open Source) ==="
composer create-project --repository-url=https://repo.magento.com/ magento/project-community-edition .

echo "=== Setting correct permissions ==="
find var generated vendor pub/static pub/media app/etc -type f -exec chmod g+w {} +
find var generated vendor pub/static pub/media app/etc -type d -exec chmod g+ws {} +
chown -R www-data:www-data .
chmod u+x bin/magento

##############################################
# Magento Install Command
##############################################

echo "=== Installing Magento ==="

bin/magento setup:install \
--base-url="https://$MAGENTO_DOMAIN/" \
--db-host="localhost" \
--db-name="$DB_NAME" \
--db-user="$DB_USER" \
--db-password="$DB_PASS" \
--admin-firstname="$ADMIN_FIRSTNAME" \
--admin-lastname="$ADMIN_LASTNAME" \
--admin-email="$ADMIN_EMAIL" \
--admin-user="$ADMIN_USER" \
--admin-password="$ADMIN_PASS" \
--language="en_US" \
--currency="USD" \
--timezone="America/New_York" \
--use-rewrites=1 \
--search-engine=opensearch \
--opensearch-host="localhost" \
--opensearch-port="9200"

##############################################
# Nginx Virtual Host
##############################################

echo "=== Creating Nginx configuration ==="

cat >/etc/nginx/sites-available/magento.conf <<EOF
server {
    listen 80;
    server_name $MAGENTO_DOMAIN;
    set \$MAGE_ROOT $MAGENTO_DIR;
    include \$MAGE_ROOT/nginx.conf.sample;
}
EOF

ln -sf /etc/nginx/sites-available/magento.conf /etc/nginx/sites-enabled/magento.conf
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

##############################################
# Magento Production Mode
##############################################

echo "=== Switching Magento to production mode ==="
bin/magento deploy:mode:set production
bin/magento cache:flush

##############################################
# CRON
##############################################

echo "=== Setting up Magento cron jobs ==="
crontab -u www-data <<EOF
* * * * * php $MAGENTO_DIR/bin/magento cron:run | grep -v "Ran jobs" >> $MAGENTO_DIR/var/log/cron.log
* * * * * php $MAGENTO_DIR/update/cron.php >> $MAGENTO_DIR/var/log/update.cron.log
* * * * * php $MAGENTO_DIR/bin/magento setup:cron:run >> $MAGENTO_DIR/var/log/setup.cron.log
EOF

##############################################
echo "=== Magento installation complete ==="
echo "Admin URL: https://$MAGENTO_DOMAIN/admin"
echo "Admin User: $ADMIN_USER"
echo "Admin Password: $ADMIN_PASS"
echo "====================================="
