#!/bin/bash

#Rename PC
read -p "ENTER PC NAME: " name
hostnamectl set-hostname $name

#Update
sudo apt update -y
sudo apt dist-upgrade -y

#Installing OpenSSH
sudo apt install openssh-server -y
sudo systemctl enable sshd
sudo systemctl start sshd
echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config
echo 'GSSAPIAuthentication yes' >> /etc/ssh/sshd_config
echo 'GSSAPICleanupCredentials no' >> /etc/ssh/sshd_config
sudo systemctl restart sshd

#Installing TeamViewer
wget https://download.teamviewer.com/download/linux/teamviewer_amd64.deb
sudo apt install ./teamviewer* -y
sudo rm teamviewer*

#Installing Anydesk
wget -qO - https://keys.anydesk.com/repos/DEB-GPG-KEY | apt-key add -
echo "deb http://deb.anydesk.com/ all main" > /etc/apt/sources.list.d/anydesk-stable.list
sudo apt update -y
sudo apt install anydesk -y

#Installing Viber
#wget https://download.cdn.viber.com/cdn/desktop/Linux/viber.deb
#chmod +x viber.deb
#sudo apt install ./viber.deb -y
#sudo apt remove viber.deb

#Update
sudo apt update -y
sudo apt dist-upgrade -y
sudo apt autoremove -y

#Reboot
sudo reboot
