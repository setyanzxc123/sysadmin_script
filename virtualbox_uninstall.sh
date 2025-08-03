#!/bin/bash

# Skrip untuk uninstall VirtualBox dan bersihkan sisa-sisa file di Ubuntu

set -e  # Stop jika ada error

echo "===> Menghapus paket VirtualBox..."
sudo apt remove --purge -y virtualbox* virtualbox-ext-pack

echo "===> Menghapus dependensi yang tidak diperlukan..."
sudo apt autoremove -y

echo "===> Menghapus file konfigurasi VirtualBox pengguna..."
rm -rf ~/.config/VirtualBox
rm -rf ~/VirtualBox\ VMs

echo "===> Menghapus file repository (jika sebelumnya pakai repo Oracle)..."
sudo rm -f /etc/apt/sources.list.d/virtualbox.list
sudo rm -f /etc/apt/trusted.gpg.d/oracle_vbox.gpg

echo "===> VirtualBox berhasil dihapus sepenuhnya."

