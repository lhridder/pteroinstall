#!/bin/bash

output(){
    echo -e '\e[36m'$1'\e[0m';
}

version=v1.2

importssh(){
apt install -y ssh-import-id
output "Import github keys () [gh:username]"
read key
if [ "$key" != "" ]; then
	ssh-import-id $key
fi
}

installdaemon() {
    output "Installing docker"
    curl -sSL https://get.docker.com/ | CHANNEL=stable bash
    systemctl enable --now docker

    output "Downloading daemon"
    mkdir -p /etc/pterodactyl
    curl -L -o /usr/local/bin/wings https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64
    chmod u+x /usr/local/bin/wings

    output "Add node on panel, server ip: $SERVER_IP"
    read choice
    eval $choice

    output "Put daemon into systemd"
    cat > /etc/systemd/system/wings.service <<- 'EOF'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=600

[Install]
WantedBy=multi-user.target
EOF
    systemctl enable wings
    systemctl reset-failed wings
    systemctl start wings
    output "Daemon install finished"
}

installpanel() {

	# get apt repos
    output "Getting apt repos"
	apt -y install software-properties-common curl apt-transport-https ca-certificates gnupg
	LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
	add-apt-repository -y ppa:chris-lea/redis-server
	curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | bash
	apt update

    output "Installing panel dependencies"
	# install panel dependencies
	apt -y install php8.0 php8.0-{cli,gd,mysql,pdo,mbstring,tokenizer,bcmath,xml,fpm,curl,zip} mariadb-server nginx tar unzip git redis-server fail2ban
	# get composer
	curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

    output "Downloading panel files"
	mkdir -p /var/www/pterodactyl
	cd /var/www/pterodactyl
	curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
	tar -xzvf panel.tar.gz
	chmod -R 755 storage/* bootstrap/cache/

    output "Installing composer"
	cp .env.example .env
	composer install --no-dev --optimize-autoloader

	output "Creating the databases and setting root password..."
    password=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1`
    adminpassword=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1`
    rootpassword=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1`
    Q0="DROP DATABASE IF EXISTS test;"
    Q1="CREATE DATABASE IF NOT EXISTS panel;"
    Q2="SET old_passwords=0;"
    Q3="GRANT ALL ON panel.* TO 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '$password';"
    Q4="GRANT all privileges ON *.* TO 'admin'@'$SERVER_IP' IDENTIFIED BY '$adminpassword' WITH GRANT OPTION;"
    Q5="SET PASSWORD FOR 'root'@'localhost' = PASSWORD('$rootpassword');"
    Q6="DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
    Q7="DELETE FROM mysql.user WHERE User='';"
    Q8="DELETE FROM mysql.db WHERE Db='test' OR Db='test\_%';"
    Q9="FLUSH PRIVILEGES;"
    SQL="${Q0}${Q1}${Q2}${Q3}${Q4}${Q5}${Q6}${Q7}${Q8}${Q9}"
    mysql -u root -e "$SQL"

    output "Setting up mysql"
    sed -i -- 's/bind-address/# bind-address/g' /etc/mysql/mariadb.conf.d/50-server.cnf
	sed -i 's/127.0.0.1/0.0.0.0/g' /etc/mysql/mariadb.conf.d/50-server.cnf
	output 'Restarting MySQL process...'
	service mysql restart

    output "Creating users and setting up database"
	php artisan key:generate --force
	php artisan p:environment:setup -n --author=$email --url=https://$FQDN --timezone=Europe/Amsterdam --cache=redis --session=database --queue=redis --redis-host=127.0.0.1 --redis-pass= --redis-port=6379
	php artisan p:environment:database --host=127.0.0.1 --port=3306 --database=panel --username=pterodactyl --password=$password
	php artisan migrate --seed --force
	php artisan p:user:make --email=$email --admin=1 --name-first="administrator" --name-last="admin"
	mysql -e "INSERT INTO panel.locations VALUES(1, 'main', 'main', '2020-04-25 04:00:30', '2020-04-25 04:00:30')"

	chown -R www-data:www-data /var/www/pterodactyl/*

	output "Creating panel queue listeners..."
    (crontab -l ; echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1")| crontab -
    service cron restart

    cat > /etc/systemd/system/pteroq.service <<- 'EOF'
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service
[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
[Install]
WantedBy=multi-user.target
EOF

    output "Starting services..."
    systemctl daemon-reload
    systemctl enable --now pteroq.service
    systemctl enable --now redis-server

    output "Disabling default configuration..."
    rm -rf /etc/nginx/sites-enabled/default
    output "Configuring Nginx Webserver..."

echo '
server_tokens off;
set_real_ip_from 103.21.244.0/22;
set_real_ip_from 103.22.200.0/22;
set_real_ip_from 103.31.4.0/22;
set_real_ip_from 104.16.0.0/12;
set_real_ip_from 104.16.0.0/13;
set_real_ip_from 104.24.0.0/14;
set_real_ip_from 108.162.192.0/18;
set_real_ip_from 131.0.72.0/22;
set_real_ip_from 141.101.64.0/18;
set_real_ip_from 162.158.0.0/15;
set_real_ip_from 172.64.0.0/13;
set_real_ip_from 173.245.48.0/20;
set_real_ip_from 188.114.96.0/20;
set_real_ip_from 190.93.240.0/20;
set_real_ip_from 197.234.240.0/22;
set_real_ip_from 198.41.128.0/17;
set_real_ip_from 2400:cb00::/32;
set_real_ip_from 2606:4700::/32;
set_real_ip_from 2803:f800::/32;
set_real_ip_from 2405:b500::/32;
set_real_ip_from 2405:8100::/32;
set_real_ip_from 2c0f:f248::/32;
set_real_ip_from 2a06:98c0::/29;
real_ip_header X-Forwarded-For;
server {
    listen 80 default_server;
    server_name '"$FQDN"';
    return 301 https://$server_name$request_uri;
}
server {
    listen 443 ssl http2 default_server;
    server_name '"$FQDN"';
    root /var/www/pterodactyl/public;
    index index.php;
    access_log /var/log/nginx/pterodactyl.app-access.log;
    error_log  /var/log/nginx/pterodactyl.app-error.log error;
    # allow larger file uploads and longer script runtimes
    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;
    # SSL Configuration
    ssl_certificate /etc/letsencrypt/live/'"$FQDN"'/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/'"$FQDN"'/privkey.pem;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2;
    ssl_ciphers 'ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA256';
    ssl_prefer_server_ciphers on;
    # See https://hstspreload.org/ before uncommenting the line below.
    # add_header Strict-Transport-Security "max-age=15768000; preload;";
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Robots-Tag none;
    add_header Content-Security-Policy "frame-ancestors 'self'";
    add_header X-Frame-Options DENY;
    add_header Referrer-Policy same-origin;
    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }
    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php8.0-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
        include /etc/nginx/fastcgi_params;
    }
    location ~ /\.ht {
        deny all;
    }
}
' | sudo -E tee /etc/nginx/sites-available/pterodactyl.conf >/dev/null 2>&1

	ln -s /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
    service nginx restart
}

ssl() {
    apt install -y dnsutils
    output "Please enter the desired user email address:"
    read email
    # dns
    output "Please enter your FQDN (panel.domain.tld):"
    read FQDN

    output "Resolving DNS..."
    SERVER_IP=$(curl -s http://checkip.amazonaws.com)
    DOMAIN_RECORD=$(dig +short ${FQDN})
    if [ "${SERVER_IP}" != "${DOMAIN_RECORD}" ]; then
        output ""
        output "The entered domain does not resolve to the primary public IP of this server."
        output "Please make an A record pointing to your server's IP. For example, if you make an A record called 'panel' pointing to your server's IP, your FQDN is panel.domain.tld"
        output "If you are using Cloudflare, please disable the orange cloud."
        exit 0
    else
        output "Domain resolved correctly. Good to go..."
    fi

    apt -y install certbot python3-certbot-nginx
    service nginx stop
    certbot certonly --standalone --email "$email" --agree-tos -d "$FQDN" --non-interactive
}

mariadb() {
  output "###############################################################"
        output "MARIADB/MySQL INFORMATION"
        output ""
        output "Your MariaDB/MySQL root password is $rootpassword"
        output ""
        output "Create your MariaDB/MySQL host with the following information:"
        output "Host: $SERVER_IP"
        output "Port: 3306"
        output "User: admin"
        output "Password: $adminpassword"
        output "###############################################################"
        output ""
}

choices() {
  output ""
  /tmp/nbashes "What do you want to install?" "Panel and Daemon" "Daemon" "Cancel"
  case $? in
  	  0 ) output "You have selected to install panel and daemon"
              ssl
              installpanel
              installdaemon
              mariadb
              ;;
          1 ) output "You have selected to only install daemon"
              ssl
              output ""
              installdaemon
              ;;
          2 ) output "Installation cancelled."
              exit 0
              ;;
          * ) output "You did not enter a valid selection."
              exit
  esac
}

# begin
echo "  _____  _                _____           _        _ _ ";
echo " |  __ \| |              |_   _|         | |      | | |";
echo " | |__) | |_ ___ _ __ ___  | |  _ __  ___| |_ __ _| | |";
echo " |  ___/| __/ _ \ '__/ _ \ | | | '_ \/ __| __/ _\` | | |";
echo " | |    | ||  __/ | | (_) || |_| | | \__ \ || (_| | | |";
echo " |_|     \__\___|_|  \___/_____|_| |_|___/\__\__,_|_|_|";
echo "                                                       ";
echo "                                                       ";
output "Ferox ptero 1.0+ installer version: $version"
output "© 2021 lhridder"
output "Script must be run on a clean Ubuntu 18.04/20.04 install under the root user"

sleep 1
importssh
sleep 1
wget -q -O /tmp/nbashes https://github.com/SnowpMakes/nbashes/releases/download/v1.0/nbashes-static-$(uname -i)
chmod +x /tmp/nbashes
/tmp/nbashes "Update machine and reboot before installing?" "Yes" "No" "Cancel"
case $? in
	0 ) output "You have selected to update the machine."
            apt update && apt upgrade -y && reboot now
            output ""
            ;;
        1 ) output "Continuing."
            output ""
            SERVER_IP=$(curl -s http://checkip.amazonaws.com)
            choices
            ;;
        2 ) output "Installation cancelled."
            exit 0
            ;;
        * ) output "You did not enter a valid selection."
            exit
esac
