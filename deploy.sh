#!/bin/bash

echo
echo "Script untuk deploy Node Docker, server harus kosong dalam kondisi baru"
echo "Pastikan IP private pada seluruh server sudah aktif dan dapat berkomunikasi"
echo "Script ini akan membuat direktori /backup , pastikan direktori /backup tidak ada di server"
echo
echo "CTRL + C jika:"
echo "- Semua server bukan server baru/kosong" 
echo "- Server belum lengkap"
echo "- IP private belum bisa terhubung"
echo
read -p "Masukkan IP PRIVATE server Node Docker: " ipprivate_node
read -p "Apakah anda ingin install nginx? nginx dapat di install di server ini atau server lain (y/n): " nginx_option
echo
read -p "Masukkan IP PUBLIC server nginx reverse proxy: " ip_nginx
read -sp "Masukkan password root server nginx reverse proxy: " pass_nginx
echo
read -sp "Masukkan password root server nginx reverse proxy (2x): " pass_nginx2
echo

if [ "$pass_nginx" != "$pass_nginx2" ]; then
	echo
	echo "Password nginx tidak cocok. Silakan coba lagi."
	exit 1
fi

echo
read -p "Apakah anda ingin install PowerDNS? PowerDNS dapat di install di server ini atau server lain (y/n): " powerdns_option
echo

if [ "$powerdns_option" == y ]; then
	read -p "Masukkan IP PUBLIC server PowerDNS: " ip_powerdns
	read -sp "Masukkan password root server PowerDNS: " pass_powerdns
	echo
	read -sp "Masukkan password root server PowerDNS (2x): " pass_powerdns2
	echo
fi

if [ "$pass_powerdns" != "$pass_powerdns2" ]; then
	echo "Password PowerDNS tidak cocok. Silakan coba lagi."
	exit 1
fi

echo
read -p "Masukkan alamat email admin (Untuk aktivasi SSL): " email_admin
echo

# buat ssh-keygen
if [ -f "/root/.ssh/id_rsa" ]; then
cat ~/.ssh/id_rsa.pub
	else
ssh-keygen -t rsa -N '' -f ~/.ssh/id_rsa <<< y
cat ~/.ssh/id_rsa.pub
fi
echo
read -p "Apakah sudah menambahkan id_rsa.pub diatas ke Github? (y/n): " github_key

if [ "$github_key" == y ]; then
	echo
	echo "Input selesai, mulai proses install..."
else
	exit
fi

sleep 3

# install library
yum update -y
yum install quota wget nano curl vim lsof git sshpass epel-release zip policycoreutils-python-utils python3-pip httpd-tools -y
pip install fastapi uvicorn

partition=$(df /home | awk 'NR==2 {print $1}')
umount /home
tune2fs -O quota $partition
mount /home
quotaon -vugP /home

# Aktifkan quota di /home
#grep -q "usrjquota=aquota.user,grpjquota=aquota.group,jqfmt=vfsv1" /etc/fstab
#if [ $? -eq 0 ]; then
#	echo "/etc/fstab terdeteksi sudah ada quota."
#	else
#	line=$(grep "^UUID=.* /home " /etc/fstab)
#	new_line=$(echo "$line" | sed 's/defaults/&,usrjquota=aquota.user,grpjquota=aquota.group,jqfmt=vfsv1/')
#	sed -i "s|$line|$new_line|" /etc/fstab
#	mount -o remount /home
#	quotacheck -cugm /home
#	quotaon -v /home
#	quotaon -ap
#fi

# Setup firewall
sed -i "s/AllowZoneDrifting=yes/AllowZoneDrifting=no/g" /etc/firewalld/firewalld.conf
systemctl enable firewalld && systemctl restart firewalld

# Install docker
dnf config-manager --add-repo=https://download.docker.com/linux/centos/docker-ce.repo
dnf install docker-ce docker-ce-cli containerd.io docker-compose-plugin -y
systemctl enable docker
systemctl start docker

# Install zabbix-agent2
# Sanity check. Tentukan dulu versi Alma 8 atau 9

repo_file="/etc/yum.repos.d/epel.repo"
exclude_line="excludepkgs=zabbix*"
os_version=$(cat /etc/os-release)

# Cek versi AlmaLinux 8 atau 9
if [[ $os_version == *"AlmaLinux 9"* ]]; then
    echo "AlmaLinux 9 terdeteksi."
    # Sanity check, periksa apakah baris sudah ada di file repositori EPEL
    if ! grep -q "$exclude_line" "$repo_file"; then
        echo "Baris '$exclude_line' tidak ditemukan di $repo_file."
        wget -P /root https://repo.zabbix.com/zabbix/7.0/alma/9/x86_64/zabbix-release-latest.el9.noarch.rpm
        rpm -Uvh /root/zabbix-release-latest.el9.noarch.rpm
        dnf clean all
		sed -i '/name=Extra Packages for Enterprise Linux \$releasever - \$basearch/a excludepkgs=zabbix*' /etc/yum.repos.d/epel.repo
        #dnf install zabbix-agent2 zabbix-agent2-plugin-* -y
		dnf install zabbix-agent2 -y
    else
        echo "Baris '$exclude_line' sudah ada di $repo_file. Tidak perlu melakukan apa-apa."
    fi

elif [[ $os_version == *"AlmaLinux 8"* ]]; then
    echo "AlmaLinux 8 terdeteksi."
    wget -P /root https://repo.zabbix.com/zabbix/7.0/alma/8/x86_64/zabbix-release-latest.el8.noarch.rpm
    rpm -Uvh /root/zabbix-release-latest.el8.noarch.rpm
    dnf clean all
    dnf install zabbix-agent2 zabbix-agent2-plugin-* -y
fi

systemctl enable zabbix-agent2

# Install Fail2Ban
dnf install fail2ban fail2ban-firewalld -y
cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
if [ -f "/etc/fail2ban/jail.d/00-firewalld.local" ]; then
	echo "firewalld.local sudah ada"
else
	mv /etc/fail2ban/jail.d/00-firewalld.conf /etc/fail2ban/jail.d/00-firewalld.local
fi

# sanity check fail2ban
if grep -q "# 3x Gagal, ban 1 jam" "/etc/fail2ban/jail.d/sshd.local" 2>/dev/null; then
	echo "fail2ban sshd.local terdeteksi sudah ada"
else
	echo "fail2ban sshd.local tidak terdeteksi. Memulai menambahkan rules..."
	touch /etc/fail2ban/jail.d/sshd.local
cat << EOF >> /etc/fail2ban/jail.d/sshd.local
# 3x Gagal, ban 1 jam 
[sshd]
enabled = true
bantime = 1h
maxretry = 3
EOF
fi

systemctl enable fail2ban
systemctl restart fail2ban

# Install Fast2API systemd, sanity check sudah ada atau belum
if [ -f "/etc/systemd/system/uvicorn.service" ]; then
	echo "File systemd uvicorn sudah ada"
else
echo "Systemd uvicorn tidak terdeteksi. Memulai menambahkan..."
touch /etc/systemd/system/uvicorn.service
cat << EOF >> /etc/systemd/system/uvicorn.service
[Unit]
Description=Uvicorn FastAPI Service for Docker Hosting v2
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
User=root
WorkingDirectory=/opt/docker-hosting-v2/script
ExecStart=python3 api.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
fi

sudo systemctl daemon-reload
sudo systemctl enable uvicorn

# Menambahkan service docker agar dipantau oleh SELinux, sanity check sudah ada atau belum
if grep -q "w /usr/bin/dockerd -k docker" "/etc/audit/rules.d/audit.rules" 2>/dev/null; then
	echo "Rules audit terdeteksi sudah ada"
else
	echo "audit.rules tidak terdeteksi. Memulai menambahkan..."
cat << EOF >> /etc/audit/rules.d/audit.rules
-w /usr/bin/dockerd -k docker
-a exit,always -F path=/run/containerd -F perm=war -k docker
-w /var/lib/docker -k docker
-w /etc/docker -k docker
-w /usr/lib/systemd/system/docker.service -k docker
-w /usr/lib/systemd/system/docker.socket -k docker
-w /etc/containerd/config.toml -k docker
-w /usr/bin/containerd-shim -k docker
-w /usr/bin/containerd-shim-runc-v1 -k docker
-w /usr/bin/containerd-shim-runc-v2 -k docker
-w /usr/bin/runc -k docker
-w /etc/docker/daemon.json -k docker
-w /run/containerd/containerd.sock -k docker
EOF
fi
service auditd restart

# Edit config docker agar lebih aman, sanity check sudah ada atau belum
if grep -q "live-restore" "/etc/docker/daemon.json" 2>/dev/null; then
	echo "Custom config docker sudah ada"
else
	echo "Custom config docker tidak terdeteksi. Memulai menambahkan..."
cat << EOF > /etc/docker/daemon.json
{
 "live-restore": true,
 "no-new-privileges": true,
 "userland-proxy" : false,
 "selinux-enabled": true,
 "icc": false
}
EOF
fi

systemctl daemon-reload

sleep 3
echo "Selesai. Berikutnya download script lalu koneksikan server ini dengan nginx reverse proxy..."
sleep 3

# Clone github, sanity check sudah ada atau belum
if [ -d "/opt/docker-hosting-v2" ]; then
	echo "Direktori /opt/docker-hosting-v2 ditemukan. Skip clone."
else
	# deploy file docker-hosting
	echo "Memulai deploy script docker-hosting-v2..."
	echo "Download script..."
	echo "Menunggu input key ke github"
	#sleep 30
	ssh-keyscan -t rsa github.com >> /root/.ssh/known_hosts
	cd /opt
	git clone -b proxysql git@github.com:sheratan17/docker-hosting-v2.git
fi

# Buat config zabbix, sanity check sudah ada atau belum
if [ -d "/etc/zabbix/scripts" ]; then
	echo "Direktori /etc/zabbix/scripts sudah ada"
else
	sudo mkdir /etc/zabbix/scripts
	mv /opt/docker-hosting-v2/script/user-quota.sh /etc/zabbix/scripts
	chmod +x /etc/zabbix/scripts/user-quota.sh
	# Edit file config zabbix-agent2
	hostname=$(hostname)
	echo "UserParameter=quota.usage,/etc/zabbix/scripts/user-quota.sh" >> "/etc/zabbix/zabbix_agent2.conf"
	sed -i "s/Hostname=Zabbix server/Hostname=$hostname/" /etc/zabbix/zabbix_agent2.conf
	# Masukkan email admin
fi

if grep -q "_email" "/opt/docker-hosting-v2/script/config.conf"; then
	sed -i "s/^email=_email/email=$email_admin/" /opt/docker-hosting-v2/script/config.conf
else
	echo "Email di config sudah ada"
fi

# Setting port firewall
firewall-cmd --zone=public --add-port=10050/tcp --permanent
firewall-cmd --zone=public --add-port=8000/tcp --permanent
firewall-cmd --remove-service=cockpit --permanent
firewall-cmd --reload

# Masukkan IP private server
# Tambahkan docker compose dari tiap CMS disini
sed -i "s/_ipprivate_node/$ipprivate_node/g" /opt/docker-hosting-v2/wp-template/docker-compose.yml
sed -i "s/_ipprivate_node/$ipprivate_node/g" /opt/docker-hosting-v2/web-template/docker-compose.yml

# Membuat nginx reverse proxy
echo
echo "Membuat nginx reverse proxy..."

ssh-keyscan -t rsa $ip_nginx >> /root/.ssh/known_hosts

if [ "$nginx_option" == y ]; then
	sshpass -p "$pass_nginx" ssh-copy-id root@$ip_nginx
	ssh root@$ip_nginx <<EOF
yum update -y
yum install epel-release -y
yum install nginx nano lsof certbot python3-certbot-nginx policycoreutils-python-utils fail2ban fail2ban-firewalld nginx-mod-modsecurity proxysql mariadb-server-utils -y
EOF
	
	# Sanity Check jail dan sshd.local apabila nginx dan docker menggunakan server yang sama
	
	sshd_rules="# 3x Gagal, ban 1 jam
	[sshd]
	enabled = true
	bantime = 1h
	maxretry = 3"
	
	copy_command="touch /etc/fail2ban/jail.d/sshd.local && cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local && mv /etc/fail2ban/jail.d/00-firewalld.conf /etc/fail2ban/jail.d/00-firewalld.local && exit"
	insert_command="echo \"$sshd_rules\" | sudo tee -a \"/etc/fail2ban/jail.d/sshd.local\" > /dev/null"
	
	if ssh "root@$ip_nginx" "grep -q '# 3x Gagal, ban 1 jam' /etc/fail2ban/jail.d/sshd.local"; then
		echo "fail2ban sshd.local terdeteksi sudah ada"
	else
		echo "fail2ban sshd.local tidak terdeteksi. Memulai menambahkan rules..."
		ssh "root@$ip_nginx" "$copy_command"
		ssh "root@$ip_nginx" "$insert_command"
	fi
	
	ssh root@$ip_nginx "systemctl enable fail2ban && systemctl restart fail2ban"
	
	# download script dan update config di nginx reverse
	# tambahkan template nginx dari tiap CMS disini
	ssh root@$ip_nginx "mv /etc/nginx/nginx.conf /etc/nginx/nginx.conf.os.default"
	scp /opt/docker-hosting-v2/server-template/nginx.conf root@$ip_nginx:/etc/nginx/ || exit 1
	scp /opt/docker-hosting-v2/server-template/*.conf.inc root@$ip_nginx:/etc/nginx/conf.d || exit 1
	scp /opt/docker-hosting-v2/server-template/status.conf root@$ip_nginx:/etc/nginx/conf.d || exit 1
	
	ssh root@$ip_nginx <<EOF
echo "Membuat SSL Self Signed untuk nginx"
server_hostname_nginx="$(hostname)"
mkdir -p /etc/ssl/nginx

openssl req -x509 -newkey rsa:4096 -keyout /etc/ssl/nginx/nginx.key -out /etc/ssl/nginx/nginx.crt -sha256 -days 3650 -nodes -subj "/C=ID/ST=Jakarta/L=Jakarta/O=Docker Hosting v2/OU=Docker Hosting v2/CN=\$server_hostname_nginx"
firewall-cmd --zone=public --add-service=http --permanent
firewall-cmd --zone=public --add-service=https --permanent
firewall-cmd --zone=public --add-port=3306/tcp --permanent
firewall-cmd --remove-service=cockpit --permanent
firewall-cmd --reload
systemctl enable nginx
systemctl disable mariadb
echo "Nginx selesai."
echo
EOF
fi

# ubah bash script agar menggunakan IP nginx
sed -i "s/_servernginx/$ip_nginx/g" /opt/docker-hosting-v2/script/config.conf
sed -i "s/_ipprivate_node_/$ipprivate_node/g" /opt/docker-hosting-v2/script/config.conf

echo "Menambahkan cronjob backup, checkquota dan sinkron jam..."
chmod +x /opt/docker-hosting-v2/script/quotacheck.sh
chmod +x /opt/docker-hosting-v2/script/backup.sh
chmod +x /opt/docker-hosting-v2/script/billing.sh
cari_crontab="billing.sh"
if crontab -l 2>/dev/null | grep -q "cari_crontab"; then
	echo "crontab ok"
else
touch /var/log/quotacheck.txt
touch /var/log/billingcheck.txt
touch /var/log/sslcheck.txt
(crontab -l ; echo "*/5 * * * * /opt/docker-hosting-v2/script/billing.sh --d=* > /var/log/billingcheck.txt 2>&1") | crontab -
(crontab -l ; echo "0 1 * * * /usr/bin/certbot renew --nginx > /var/log/sslcheck.txt 2>&1") | crontab -
echo "crontab ditambahkan"
fi

timedatectl set-timezone Asia/Jakarta
timedatectl set-ntp on

if [ -d "/backup" ]; then
	echo "Direktori /backup sudah ada"
else
mkdir /backup
fi

pdns_password=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 12)
pdns_api=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 12)

pdns_config_line="
# Configurasi tambahan
api=yes
api-key=$pdns_api
webserver-address=127.0.0.1
webserver-allow-from=127.0.0.1
webserver-password=$pdns_api
webserver-port=8081
launch=gmysql
gmysql-host=localhost
gmysql-dbname=pdns
gmysql-user=pdnsadmin
gmysql-password=$pdns_password

#Dibawah ini adalah konfigurasi untuk clustering bagian master
#gmysql-dnssec=no
#primary=yes
#secondary=no
#xfr-cycle-interval=10
#log-dns-queries=yes
#log-timestamp=yes
#query-logging=yes
#disable-syslog=no

#Tambahkan juga baris dibawah ini untuk bagian slave 
#allow-dnsupdate-from=IP_MASTER
#allow-axfr-ips=IP_MASTER
#allow-notify-from=IP_MASTER
#autosecondary=no
"
pdns_sql="
CREATE DATABASE pdns;
GRANT ALL PRIVILEGES ON pdns.* TO 'pdnsadmin'@'localhost' IDENTIFIED BY '$pdns_password';
FLUSH PRIVILEGES;
"

ssh-keyscan -t rsa $ip_powerdns >> /root/.ssh/known_hosts

if [ "$powerdns_option" == y ]; then
	pdns_config_line2="Configurasi tambahan"
	sshpass -p "$pass_powerdns" ssh-copy-id root@$ip_powerdns
	ssh "root@$ip_powerdns" "grep -q '${pdns_config_line2}' '/etc/pdns/pdns.conf'"
	if [ $? -eq 0 ]; then
  	echo "Konfigurasi PowerDNS sudah ada"
	else
	ssh "root@$ip_powerdns" <<EOF
echo "Install PowerDNS..."
curl -o /etc/yum.repos.d/powerdns-auth-49.repo https://repo.powerdns.com/repo-files/el-auth-49.repo
yum install pdns pdns-backend-mysql mariadb-server -y
systemctl enable mariadb
systemctl enable pdns
systemctl restart mariadb
echo "$pdns_config_line" >> /etc/pdns/pdns.conf
chown pdns:pdns /etc/pdns/pdns.conf
sed -i s/powerdns_api_key/$pdns_api/g /etc/pdns/pdns.conf
mysql -u root -e "$pdns_sql"
firewall-cmd --zone=public --add-service=dns --permanent
firewall-cmd --zone=public --add-port=8081/tcp --permanent
firewall-cmd --remove-service=cockpit --permanent
mysql -u root pdns < /usr/share/doc/pdns-backend-mysql/schema.mysql.sql
(crontab -l ; echo "*/5 * * * * /usr/bin/pdns_control notify "*" > /var/log/notify.txt 2>&1") | crontab -
EOF
	fi
fi

# Menambahkan IP dan APIKEY powerdns ke config.conf
sed -i "s/APIKEY=powerdns_api_key/APIKEY=$pdns_api/g" /opt/docker-hosting-v2/script/config.conf
sed -i "s/_serverdns/$ip_powerdns/g" /opt/docker-hosting-v2/script/config.conf
	
# Buat ssl self signed untuk API
echo "Membuat SSL Self Signed untuk API"
server_hostname="api.$(hostname)"
ssl_dir="/etc/ssl/docker-hosting"
mkdir -p $ssl_dir

file_crt="$ssl_dir/api.crt"
file_key="$ssl_dir/api.key"
file_csr="$ssl_dir/api.csr"

openssl req -x509 -newkey rsa:4096 -keyout $file_key -out $file_crt -sha256 -days 3650 -nodes -subj "/C=ID/ST=Jakarta/L=Jakarta/O=Docker Hosting v2/OU=Docker Hosting v2/CN=$server_hostname"

# Config awal proxysql
proxysql_config="
mysql -u admin -padmin -h 127.0.0.1 -P6032 --prompt 'ProxySQL Admin> ' <<EOF
UPDATE global_variables SET variable_value='monitor' WHERE variable_name='mysql-monitor_username';
UPDATE global_variables SET variable_value='Monitor123' WHERE variable_name='mysql-monitor_password';
UPDATE global_variables SET variable_value='2000' WHERE variable_name IN ('mysql-monitor_connect_interval','mysql-monitor_ping_interval','mysql-monitor_read_only_interval');
SELECT * FROM global_variables WHERE variable_name LIKE 'mysql-monitor_%';
LOAD MYSQL VARIABLES TO RUNTIME;
SAVE MYSQL VARIABLES TO DISK;
LOAD MYSQL SERVERS TO RUNTIME;
EOF
"

ssh -p root@$ip_nginx "systemctl start proxysql"
ssh -p root@$ip_nginx "$proxysql_config"

echo "Download image docker..."
docker image pull mariadb:10.11.10-jammy
docker image pull sheratan17/php:8.3.15-apache-im
docker image pull wordpress:6.7.1-php8.3
docker image pull phpmyadmin:5.2.1-apache
docker image pull filebrowser/filebrowser:s6
echo
echo "SCRIPT DEPLOY SELESAI."
echo
echo "Mohon jalankan 'yum update' pada server Node Docker dan nginx, lalu restart."
echo "Mohon menunggu 5-10 menit sebelum membuat container untuk melewati masa propagasi DNS Server."
echo "Mohon cek pra-installasi.txt untuk tutorial setting PowerDNS"
echo "Untuk proses installasi dan menghubungkan ke server Zabbix, silahkan cek petunjuk yang telah dibuat."
echo
exit 1
