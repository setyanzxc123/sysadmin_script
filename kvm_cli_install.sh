#!/bin/bash

# Skrip instalasi KVM full CLI-only untuk Ubuntu Server

set -e  # Stop jika ada error

echo "===> Memperbarui sistem..."
sudo apt update

echo "===> Menginstal paket KVM dan alat manajemen VM (CLI-only)..."
sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virtinst cpu-checker

echo "===> Menambahkan user '$USER' ke grup 'kvm' dan 'libvirt'..."
sudo usermod -aG kvm $USER
sudo usermod -aG libvirt $USER

echo "===> Mengecek dukungan virtualisasi CPU..."
kvm-ok || echo "⚠️ CPU kamu mungkin belum mendukung atau virtualisasi belum aktif di BIOS."

echo "===> Mengaktifkan dan menjalankan layanan libvirtd..."
sudo systemctl enable --now libvirtd

echo "===> Verifikasi koneksi libvirt..."
virsh list --all

echo "✅ Instalasi KVM selesai. Silakan logout & login kembali agar grup aktif."

