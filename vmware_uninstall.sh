#!/bin/bash

# Skrip untuk uninstall VMware Workstation Player di Ubuntu
# Harus dijalankan dengan akses sudo

set -e  # Hentikan jika ada error

echo "===> Mencari installer VMware .bundle yang lama..."
INSTALLER=$(ls -1 /usr/lib/vmware/installer/*.installer.bundle 2>/dev/null | head -n 1)

if [[ -z "$INSTALLER" ]]; then
  echo "!! Tidak menemukan file uninstaller di /usr/lib/vmware/installer/"
  echo "!! VMware mungkin tidak terinstal dengan cara biasa."
  echo "!! Silakan coba hapus manual dengan: sudo vmware-installer -u vmware-player"
  exit 1
fi

echo "===> Menjalankan uninstaller..."
sudo vmware-installer -u vmware-player --required --console

echo "===> Membersihkan sisa file (jika ada)..."
sudo rm -rf /etc/vmware*
sudo rm -rf /usr/lib/vmware*
sudo rm -rf ~/.vmware

echo "===> VMware Workstation Player berhasil dihapus."

