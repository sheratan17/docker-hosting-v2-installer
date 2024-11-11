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
echo
read -p "Masukkan IP PUBLIC server nginx reverse proxy: " ip_nginx
read -sp "Masukkan password root server nginx reverse proxy: " pass_nginx
echo
read -sp "Masukkan password root server nginx reverse proxy (2x): " pass_nginx2
echo
read -p "Apakah anda ingin install nginx di server ini? (y/n): " nginx_option
read -p "Apakah anda ingin install PowerDNS di server ini? (y/n): " powerdns_option
echo

if [ "$pass_nginx" != "$pass_nginx2" ]; then
	echo "Password tidak cocok. Silakan coba lagi."
	exit 1
fi

# install library
yum update -y
yum install quota wget nano curl vim lsof git sshpass epel-release zip policycoreutils-python-utils python3-pip httpd-tools -y
pip install fastapi uvicorn

# Aktifkan quota di /home
grep -q "usrjquota=aquota.user,grpjquota=aquota.group,jqfmt=vfsv1" /etc/fstab

if [ $? -eq 0 ]; then
	echo "/etc/fstab terdeteksi sudah ada quota."
	else
	line=$(grep "^UUID=.* /home " /etc/fstab)
	new_line=$(echo "$line" | sed 's/defaults/&,usrjquota=aquota.user,grpjquota=aquota.group,jqfmt=vfsv1/')
	sed -i "s|$line|$new_line|" /etc/fstab
	mount -o remount /home
	quotacheck -cugm /home
	quotaon -v /home
	quotaon -ap
fi

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
        dnf install zabbix-agent2 zabbix-agent2-plugin-* -y
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
mv /etc/fail2ban/jail.d/00-firewalld.conf /etc/fail2ban/jail.d/00-firewalld.local
touch /etc/fail2ban/jail.d/sshd.local
cat << EOF >> /etc/fail2ban/jail.d/sshd.local
# 3x Gagal, ban 1 jam 
[sshd]
enabled = true
bantime = 1h
maxretry = 3
EOF
systemctl enable fail2ban
systemctl restart fail2ban

# Install Fast2API systemd
touch /etc/systemd/system/uvicorn.service
cat << EOF >> /etc/systemd/system/uvicorn.service
[Unit]
Description=Uvicorn FastAPI Service for Docker Hosting v2
After=network.target

[Service]
User=root
WorkingDirectory=/opt/docker-hosting-v2/script
ExecStart=/usr/local/bin/uvicorn api:app --host 0.0.0.0 --port 8000
Restart=always

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable uvicorn

# Menambahkan service docker agar dipantau oleh SELinux
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
EOF
service auditd restart

# Edit config docker agar lebih aman
cat << EOF > /etc/docker/daemon.json
{
 "live-restore": true,
 "no-new-privileges": true,
 "userland-proxy" : false,
 "selinux-enabled": true
}
EOF

# buat ssh-keygen
#ssh-keygen -t rsa -N '' -f ~/.ssh/id_rsa <<< y

systemctl daemon-reload

sleep 3
echo "Selesai. Berikutnya download script lalu koneksikan server ini dengan nginx reverse proxy..."
sleep 3

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
	git clone git@github.com:sheratan17/docker-hosting-v2.git
fi

mkdir /etc/zabbix/scripts
mv /opt/docker-hosting-v2/script/user-quota.sh /etc/zabbix/scripts
chmod +x /etc/zabbix/scripts/user-quota.sh

# Edit file config zabbix-agent2
hostname=$(hostname)
echo "UserParameter=quota.usage,/etc/zabbix/scripts/user-quota.sh" >> "/etc/zabbix/zabbix_agent2.conf"
sed -i "s/Hostname=Zabbix server/Hostname=$hostname/" /etc/zabbix/zabbix_agent2.conf

# Setting port zabbix-agent di node docker
firewall-cmd --zone=public --add-port=10050/tcp --permanent
firewall-cmd --zone=public --add-port=8000/tcp --permanent
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
	ssh root@$ip_nginx "yum update -y && yum install epel-release -y && exit"
	ssh root@$ip_nginx "yum install nginx nano lsof certbot python3-certbot-nginx policycoreutils-python-utils fail2ban fail2ban-firewalld -y && exit"
	
	# Sanity Check jail dan sshd.local apabila nginx dan docker menggunakan server yang sama
	
	content_to_insert="# 3x Gagal, ban 1 jam
	[sshd]
	enabled = true
	bantime = 1h
	maxretry = 3"
	
	copy_command="touch /etc/fail2ban/jail.d/sshd.local && cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local && mv /etc/fail2ban/jail.d/00-firewalld.conf /etc/fail2ban/jail.d/00-firewalld.local && exit"
	insert_command="echo \"$content_to_insert\" | sudo tee -a \"/etc/fail2ban/jail.d/sshd.local\" > /dev/null"
	
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
	sed -i "s/_ipprivate_node/$ipprivate_node/g" /opt/docker-hosting-v2/server-template/web-template.conf.inc
	sed -i "s/_ipprivate_node/$ipprivate_node/g" /opt/docker-hosting-v2/server-template/wp-template.conf.inc
	scp /opt/docker-hosting-v2/server-template/*.conf.inc root@$ip_nginx:/etc/nginx/conf.d || exit 1
	#ssh root@$ip_nginx 'sed -i "/http {/a \    server_tokens off;" /etc/nginx/nginx.conf && exit'
	
	# ubah bash script agar menggunakan IP nginx
	sed -i "s/_servernginx/$ip_nginx/g" /opt/docker-hosting-v2/script/config.conf
	sed -i "s/_ipprivate_node_/$ipprivate_node/g" /opt/docker-hosting-v2/script/config.conf
	
	ssh root@$ip_nginx "firewall-cmd --zone=public --add-service=http --permanent"
	ssh root@$ip_nginx "firewall-cmd --zone=public --add-service=https --permanent"
	ssh root@$ip_nginx "firewall-cmd --reload && exit"
	ssh root@$ip_nginx "systemctl enable nginx && exit"
	echo "Nginx selesai."
	echo
fi

echo "Menambahkan cronjob backup, checkquota dan sinkron jam..."
chmod +x /opt/docker-hosting-v2/script/quotacheck.sh
chmod +x /opt/docker-hosting-v2/script/backup.sh
(crontab -l ; echo "*/5 * * * * /opt/docker-hosting-v2/script/quotacheck.sh > /var/log/quotacheck.txt 2>&1") | crontab -
timedatectl set-timezone Asia/Jakarta
timedatectl set-ntp on

mkdir /backup

pdns_password=$(openssl rand -base64 12)
pdns_api=$(openssl rand -base64 14)

pdns_config_line="
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
"
pdns_sql="
CREATE DATABASE pdns;
GRANT ALL PRIVILEGES ON pdns.* TO 'pdnsadmin'@'localhost' IDENTIFIED BY '$pdns_password';
FLUSH PRIVILEGES;
"

if [ "$powerdns_option" == y ]; then
	echo "Install PowerDNS..."
	curl -o /etc/yum.repos.d/powerdns-auth-49.repo https://repo.powerdns.com/repo-files/el-auth-49.repo
	yum install pdns pdns-backend-mysql mariadb-server -y
	systemctl enable mariadb
	systemctl enable pdns
	systemctl restart mariadb
	echo "$pdns_config_line" >> "/etc/pdns/pdns.conf"
	chown pdns:pdns /etc/pdns/pdns.conf
	mysql -u root -e "$pdns_sql"
fi

echo "Download image docker..."
docker image pull mariadb:10.11.9-jammy
docker image pull sheratan17/php8.2-apache:v1
docker image pull wordpress:6.6.2-php8.3
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
