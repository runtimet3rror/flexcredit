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
#wget https://download.teamviewer.com/download/linux/teamviewer_amd64.deb
#sudo apt install ./teamviewer* -y
#sudo rm teamviewer*

#Installing Anydesk
#wget -qO - https://keys.anydesk.com/repos/DEB-GPG-KEY | apt-key add -
#echo "deb http://deb.anydesk.com/ all main" > /etc/apt/sources.list.d/anydesk-stable.list
sudo apt update -y
sudo apt install anydesk -y

#Installing RustDesk
wget https://github.com/rustdesk/rustdesk/releases/download/1.2.2/rustdesk-1.2.2-x86_64.deb
sudo apt install ./rustdesk-1.2.2-x86_64.deb -y
sudo rm rustdesk-1.2.2-x86_64.deb
sudo systemctl enable rustdesk.service

#Installing Viber
#wget https://download.cdn.viber.com/cdn/desktop/Linux/viber.deb
#chmod +x viber.deb
#sudo apt install ./viber.deb -y
#sudo apt remove viber.deb

#Update
sudo apt update -y
sudo apt dist-upgrade -y
sudo apt autoremove -y

#Fix Mic in Ubuntu install on Logitech H111 headset
file_path="/etc/modprobe.d/alsa-base.conf"
line_to_add="options snd-hda-intel model=dell-headset-multi"

if [ -f "$file_path" ]; then
  echo "$line_to_add" | sudo tee -a "$file_path"
  echo "Line added to $file_path"
else
  echo "File not found: $file_path"
fi

#Reboot
sudo reboot
