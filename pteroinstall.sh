#!/bin/bash

output(){
    echo -e '\e[36m'$1'\e[0m';
}

version=v1.0

importssh(){
apt install -y ssh-import-id
output "Import github keys () [gh:username]"
read key
if [ "$key" != "" ]; then
	ssh-import-id $key
fi
}

installptero(){
	output "Getting dependencies..."
	apt install -y mariadb-common mariadb-server mariadb-client php7.4 php7.4-{cli,gd,mysql,pdo,mbstring,tokenizer,bcmath,xml,fpm,curl,zip} nginx redis-server certbot curl tar unzip git redis-server nginx git wget expect software-properties-common curl apt-transport-https ca-certificates gnupg 
	systemctl start mariadb
	systemctl enable mariadb
	systemctl start redis-server
	systemctl enable redis-server
	# email
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
        output "If you do not have a domain, you can get a free one at https://freenom.com"
        dns_check
    else 
        output "Domain resolved correctly. Good to go..."
    fi

    #mysql
    output "Creating the databases and setting root password..."
    password=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1`
    adminpassword=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1`
    rootpassword=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1`
    Q0="DROP DATABASE IF EXISTS test;"
    Q1="CREATE DATABASE IF NOT EXISTS panel;"
    Q2="SET old_passwords=0;"
    Q3="GRANT ALL ON panel.* TO 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '$password';"
    Q4="GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, DROP, EXECUTE, PROCESS, RELOAD, LOCK TABLES, CREATE USER ON *.* TO 'admin'@'$SERVER_IP' IDENTIFIED BY '$adminpassword' WITH GRANT OPTION;"
    Q5="SET PASSWORD FOR 'root'@'localhost' = PASSWORD('$rootpassword');"
    Q6="DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
    Q7="DELETE FROM mysql.user WHERE User='';"
    Q8="DELETE FROM mysql.db WHERE Db='test' OR Db='test\_%';"
    Q9="FLUSH PRIVILEGES;"
    SQL="${Q0}${Q1}${Q2}${Q3}${Q4}${Q5}${Q6}${Q7}${Q8}${Q9}"
    mysql -u root -e "$SQL"

    output "Binding MariaDB/MySQL to 0.0.0.0."
    if [ -f /etc/mysql/mariadb.conf.d/50-server.cnf ] ; then
        sed -i -- 's/bind-address/# bind-address/g' /etc/mysql/mariadb.conf.d/50-server.cnf
		sed -i 's/127.0.0.1/0.0.0.0/g' /etc/mysql/mariadb.conf.d/50-server.cnf
		output 'Restarting MySQL process...'
		service mysql restart
	elif [ -f /etc/mysql/my.cnf ] ; then
        	sed -i -- 's/bind-address/# bind-address/g' /etc/mysql/my.cnf
		sed -i '/\[mysqld\]/a bind-address = 0.0.0.0' /etc/mysql/my.cnf
		output 'Restarting MySQL process...'
		service mysql restart
	elif [ -f /etc/my.cnf ] ; then
        sed -i -- 's/bind-address/# bind-address/g' /etc/my.cnf
		sed -i '/\[mysqld\]/a bind-address = 0.0.0.0' /etc/my.cnf
		output 'Restarting MySQL process...'
		service mysql restart
    elif [ -f /etc/mysql/my.conf.d/mysqld.cnf ] ; then
        sed -i -- 's/bind-address/# bind-address/g' /etc/mysql/my.conf.d/mysqld.cnf
		sed -i '/\[mysqld\]/a bind-address = 0.0.0.0' /etc/mysql/my.conf.d/mysqld.cnf
		output 'Restarting MySQL process...'
		service mysql restart
	else 
		output 'File my.cnf was not found! Please contact support.'
	fi

	# panel
	systemctl enable php7.4-fpm
	systemctl start php7.4-fpm
	mkdir -p /var/www/pterodactyl
	cd /var/www/pterodactyl
	curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
	tar -xzvf panel.tar.gz
	chmod -R 755 storage/* bootstrap/cache/
	cp .env.example .env
	composer install --no-dev --optimize-autoloader

	# Only run the command below if you are installing this Panel for
	# the first time and do not have any Pterodactyl Panel data in the database.
	php artisan key:generate --force
	php artisan p:environment:setup
	php artisan p:environment:database

	# To use PHP's internal mail sending (not recommended), select "mail". To use a
	# custom SMTP server, select "smtp".
	php artisan p:environment:mail
	php artisan migrate --seed --force

	#TODO user
	php artisan p:user:make

	chown -R www-data:www-data /var/www/pterodactyl/*


}


# begin

output "Ferox ptero 1.0 installer version: $version"
output "© 2021 lhridder"
output ""
output "Update machine and reboot? (yes/no)"

read choice
case $choice in
	yes ) output "You have selected to update the machine."
            apt update && apt upgrade && reboot now
            output ""
            ;;
        no ) output "Continueing."
            output ""
            importssh
            installptero
            ;;
        * ) output "You did not enter a valid selection."
            exit
esac