#!/bin/bash

# Skrip instalasi otomatis VirtualBox di Ubuntu
# Diuji pada Ubuntu 20.04 / 22.04 / 24.04

set -e  # Stop jika ada error

echo "===> Memperbarui daftar paket..."
sudo apt update

echo "===> Menginstal dependensi awal..."
sudo apt install -y software-properties-common curl gnupg

echo "===> Menambahkan repository VirtualBox resmi..."
wget -q https://www.virtualbox.org/download/oracle_vbox_2016.asc -O- | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/oracle_vbox.gpg
echo "deb [arch=amd64 signed-by=/etc/apt/trusted.gpg.d/oracle_vbox.gpg] https://download.virtualbox.org/virtualbox/debian $(lsb_release -cs) contrib" | sudo tee /etc/apt/sources.list.d/virtualbox.list

echo "===> Memperbarui daftar paket kembali..."
sudo apt update

echo "===> Menginstal VirtualBox (versi terbaru yang tersedia)..."
sudo apt install -y virtualbox virtualbox-ext-pack

echo "===> Menyelesaikan instalasi."
vboxmanage --version && echo "VirtualBox berhasil diinstal."

# Opsional: Tambahkan user ke grup vboxusers
echo "===> Menambahkan user '$USER' ke grup 'vboxusers' (perlu logout-login setelah ini)..."
sudo usermod -aG vboxusers $USER

echo "===> Instalasi selesai. Silakan logout dan login kembali agar grup vboxusers aktif."

