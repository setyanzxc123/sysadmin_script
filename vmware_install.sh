#!/bin/bash

# Skrip instalasi otomatis VMware Workstation Player di Ubuntu
# Pastikan kamu menggunakan Ubuntu 20.04 / 22.04 / 24.04
# Dibutuhkan koneksi internet dan akses sudo

set -e  # Hentikan skrip jika ada error

# Versi VMware yang ingin diunduh (ubah sesuai versi resmi terbaru jika perlu)
VMWARE_VERSION="17.5.0"
VMWARE_BUNDLE="VMware-Player-${VMWARE_VERSION}-23298084.x86_64.bundle"
DOWNLOAD_URL="https://download3.vmware.com/software/player/${VMWARE_BUNDLE}"

echo "===> Memperbarui sistem..."
sudo apt update

echo "===> Menginstal dependensi build dan kernel headers..."
sudo apt install -y build-essential linux-headers-$(uname -r) dkms

echo "===> Mengunduh VMware Workstation Player..."
wget -c "$DOWNLOAD_URL" -O "$VMWARE_BUNDLE"

echo "===> Menambahkan permission eksekusi ke installer..."
chmod +x "$VMWARE_BUNDLE"

echo "===> Menjalankan installer VMware Player..."
sudo ./"$VMWARE_BUNDLE" --required --eulas-agreed --console

echo "===> Instalasi selesai."

