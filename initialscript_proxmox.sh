#!/usr/bin/env bash
# ===== Logging =====
mkdir -p /root
exec > >(tee -a /root/initialscript_proxmox.log) 2>&1
set -euo pipefail

# ===== Utils =====
log(){ printf "\n\033[1;32m[%s]\033[0m %s\n" "$(date '+%F %T')" "$*"; }
warn(){ printf "\n\033[1;33m[%s][WARN]\033[0m %s\n" "$(date '+%F %T')" "$*"; }
die(){ printf "\n\033[1;31m[%s][ERR]\033[0m %s\n" "$(date '+%F %T')" "$*"; exit 1; }

ensure_pkg(){ apt-get -y install "$@" >/dev/null 2>&1 || apt -y install "$@"; }
is_wireless(){ [[ -d "/sys/class/net/$1/wireless" ]] && return 0 || return 1; }

prefix_to_netmask(){ # 24 -> 255.255.255.0
  local p=$1 m=() n i; for i in {1..4}; do
    if ((p>=8)); then n=255; elif ((p<=0)); then n=0; else n=$((256-2**(8-p))); fi
    m+=("$n"); p=$((p-8))
  done; printf "%s.%s.%s.%s" "${m[@]}"
}

detect_if(){ ip -4 route list default | awk '{print $5}' | head -n1; }
detect_cidr(){ ip -4 addr show dev "$1" | awk '/inet /{print $2}' | head -n1; }
detect_gw(){ ip -4 route list default | awk '{print $3}' | head -n1; }

[[ $EUID -eq 0 ]] || die "Jalankan sebagai root: sudo -i atau sudo bash $0"
grep -qi "bookworm" /etc/os-release || warn "Skrip ini ditulis untuk Debian 12 (Bookworm)."

# ===== Matikan repo enterprise SEBELUM apt update =====
log "Menonaktifkan repo Proxmox enterprise (jika ada)…"
for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
  [[ -f "$f" ]] || continue
  sed -i -E 's|^([[:space:]]*)deb ([^#]*enterprise\.proxmox\.com[^#]*)|# \1deb \2|g' "$f" || true
  sed -i -E 's|^([[:space:]]*)deb ([^#]*pve-enterprise[^#]*)|# \1deb \2|g' "$f" || true
done

# ===== Deteksi jaringan host =====
log "Deteksi NIC & IP host…"
MAIN_IF=$(detect_if); [[ -n "${MAIN_IF:-}" ]] || die "Tidak menemukan NIC default route."
CIDR=$(detect_cidr "$MAIN_IF"); [[ -n "${CIDR:-}" ]] || die "Tidak menemukan IPv4 pada $MAIN_IF."
IP4="${CIDR%/*}"; PREFIX="${CIDR#*/}"; NETMASK=$(prefix_to_netmask "$PREFIX")
GATE=$(detect_gw) || die "Gateway tidak ditemukan."
DNS=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null || echo "")
WIRELESS="NO"; is_wireless "$MAIN_IF" && WIRELESS="YES"
log "Interface utama: $MAIN_IF  (Wi-Fi? $WIRELESS)  IP: $IP4/$PREFIX  GW: $GATE"

# ===== Hostname & /etc/hosts (FQDN wajib) =====
log "Set hostname (FQDN) & /etc/hosts…"
CUR_SHORT=$(hostnamectl --static)
CUR_FQDN=$(hostname -f 2>/dev/null || echo "$CUR_SHORT")
if [[ "$CUR_FQDN" == *.* ]]; then
  HOST_FQDN="$CUR_FQDN"; HOST_SHORT="${CUR_SHORT%%.*}"
else
  HOST_FQDN="pve.local"; HOST_SHORT="pve"
  warn "Hostname belum FQDN → set sementara ke $HOST_FQDN"
  hostnamectl set-hostname "$HOST_FQDN"
fi
cat >/etc/hosts <<EOF
127.0.0.1       localhost
$IP4            $HOST_FQDN $HOST_SHORT
EOF

# ===== Update & alat bantu =====
log "Update sistem & pasang alat bantu…"
export DEBIAN_FRONTEND=noninteractive
apt update
apt -y full-upgrade
ensure_pkg curl wget gnupg ca-certificates apt-transport-https systemd-sysv util-linux ifupdown2

# ===== Repo Proxmox (no-subscription) =====
log "Tambah repo Proxmox (no-subscription) & import key…"
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" \
  > /etc/apt/sources.list.d/pve-install-repo.list
wget -qO /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg \
  https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg
chmod +r /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg
apt update

# ===== Install Proxmox =====
log "Install Proxmox VE (postfix=Local only)…"
echo "postfix postfix/main_mailer_type select Local only" | debconf-set-selections
echo "postfix postfix/mailname string ${HOST_FQDN}"       | debconf-set-selections
apt -y install proxmox-ve postfix open-iscsi

log "Hapus kernel Debian lama (opsional)…"
apt -y remove linux-image-amd64 'linux-image-6.*-amd64' || true

# ===== Network: dua mode =====
[[ -f /etc/network/interfaces ]] && cp -a /etc/network/interfaces /etc/network/interfaces.bak.$(date +%s)

if [[ "$WIRELESS" == "NO" ]]; then
  # --- MODE KABEL: bridge langsung (vmbr0) ---
  log "MODE KABEL: pindah IP host ke bridge vmbr0 (best practice)…"
  cat >/etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

auto $MAIN_IF
iface $MAIN_IF inet manual

auto vmbr0
iface vmbr0 inet static
    address $IP4
    netmask $NETMASK
    gateway $GATE
    bridge-ports $MAIN_IF
    bridge-stp off
    bridge-fd 0
EOF

else
  # --- MODE WI-FI: jangan sentuh koneksi host; buat vmbr0 dummy + NAT ---
  log "MODE WI-FI: biarkan $MAIN_IF tetap DHCP; buat vmbr0 dummy + NAT untuk VM…"
  # Jaringan internal VM
  VM_NET="192.168.100.0/24"
  VM_BR_IP="192.168.100.1"
  VM_NETMASK="255.255.255.0"

  cat >/etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

allow-hotplug $MAIN_IF
iface $MAIN_IF inet dhcp

auto vmbr0
iface vmbr0 inet static
    address $VM_BR_IP
    netmask $VM_NETMASK
    bridge-ports none
    bridge-stp off
    bridge-fd 0
EOF

  # NAT dengan iptables (nft-compat)
  log "Aktifkan IP forwarding + NAT (masquerade) dari vmbr0 -> $MAIN_IF…"
  sed -i '/^net.ipv4.ip_forward/d' /etc/sysctl.conf || true
  echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
  sysctl -p || true

  ensure_pkg iptables-persistent
  iptables -t nat -D POSTROUTING -s $VM_NET -o $MAIN_IF -j MASQUERADE 2>/dev/null || true
  iptables -t nat -A POSTROUTING -s $VM_NET -o $MAIN_IF -j MASQUERADE
  netfilter-persistent save

  # DHCP sederhana untuk VM (dnsmasq)
  log "(Opsional) Menyediakan DHCP untuk VM via dnsmasq pada vmbr0…"
  ensure_pkg dnsmasq
  cat >/etc/dnsmasq.d/pve-vmbr0.conf <<EOF
interface=vmbr0
bind-interfaces
dhcp-range=192.168.100.50,192.168.100.200,12h
dhcp-option=3,$VM_BR_IP
dhcp-option=6,1.1.1.1,8.8.8.8
EOF
  systemctl restart dnsmasq
fi

# ===== Perapihan single-node cluster =====
log "Perapihan cluster single-node…"
systemctl stop pve-cluster || true
rm -rf /etc/corosync/* 2>/dev/null || true
umount /etc/pve 2>/dev/null || true
systemctl start pve-cluster
systemctl enable pve-cluster

# ===== Restart layanan =====
log "Restart networking & layanan Proxmox…"
systemctl restart networking || true
systemctl restart pve-cluster pvedaemon pveproxy pvestatd || true
systemctl enable  pvedaemon pveproxy pvestatd || true

# ===== Ringkasan =====
log "Ringkasan:"
echo "  Log file     : /root/initialscript_proxmox.log"
echo "  Hostname     : $(hostname -f)"
echo "  Kernel aktif : $(uname -r)  (PVE? $(uname -r | grep -q pve && echo YA || echo TIDAK))"
echo "  NIC utama    : $MAIN_IF  (Wi-Fi? $WIRELESS)"
if [[ "$WIRELESS" == "NO" ]]; then
  echo "  Akses WebUI  : https://$IP4:8006"
  echo "  Bridge       : vmbr0 (bridged ke $MAIN_IF) — VM pakai DHCP/router rumah"
else
  echo "  Akses WebUI  : https://$IP4:8006"
  echo "  Bridge       : vmbr0 (dummy $VM_BR_IP/24, NAT → $MAIN_IF)"
  echo "  DHCP VM      : via dnsmasq (range 192.168.100.50–200)"
fi
warn "Jika WebUI belum bisa, reboot sekali:  reboot"