#!/usr/bin/env bash
set -euo pipefail

log(){ printf "\n\033[1;32m[%s]\033[0m %s\n" "$(date +%H:%M:%S)" "$*"; }
warn(){ printf "\n\033[1;33m[WARN]\033[0m %s\n" "$*"; }
die(){ printf "\n\033[1;31m[ERR]\033[0m %s\n" "$*"; exit 1; }

[[ $EUID -eq 0 ]] || die "Jalankan sebagai root (sudo -i)."

# -------- Helpers --------
prefix_to_netmask(){ # $1=prefix (e.g. 24) -> 255.255.255.0
  local p=$1; local mask=(); local i
  for i in 1 2 3 4; do
    local n=$(( p>=8 ? 255 : (p<=0 ? 0 : (256 - 2**(8-p)) ) ))
    mask+=("$n"); p=$(( p-8 ))
  done
  printf "%s.%s.%s.%s" "${mask[@]}"
}

detect_main_if(){
  ip -4 route list default | awk '{print $5}' | head -n1
}

detect_ip_cidr(){
  ip -4 addr show dev "$1" | awk '/inet /{print $2}' | head -n1
}

detect_gateway(){
  ip -4 route list default | awk '{print $3}' | head -n1
}

ensure_pkg(){ apt-get -y install "$@" >/dev/null 2>&1 || apt -y install "$@"; }

# -------- Checks --------
if ! grep -qi "bookworm" /etc/os-release; then
  warn "Skrip ini ditulis untuk Debian 12 (Bookworm). Lanjutkan atas risiko sendiri."
fi

log "Deteksi NIC & IP…"
MAIN_IF=$(detect_main_if) || true
[[ -n "${MAIN_IF:-}" ]] || die "Tidak menemukan NIC default route."
CIDR=$(detect_ip_cidr "$MAIN_IF") || true
[[ -n "${CIDR:-}" ]] || die "Tidak menemukan IPv4 pada $MAIN_IF."
IP4="${CIDR%/*}"; PREFIX="${CIDR#*/}"
GATE=$(detect_gateway) || die "Tidak menemukan gateway."
NETMASK=$(prefix_to_netmask "$PREFIX")
DNS=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null || true)

log "Hostname & FQDN…"
CUR_SHORT=$(hostnamectl --static)
CUR_FQDN=$(hostname -f 2>/dev/null || echo "$CUR_SHORT")
if [[ "$CUR_FQDN" == *.* ]]; then
  HOST_FQDN="$CUR_FQDN"; HOST_SHORT="${CUR_SHORT%%.*}"
else
  HOST_FQDN="pve.local"; HOST_SHORT="pve"
  warn "Hostname belum FQDN. Mengatur ke $HOST_FQDN"
  hostnamectl set-hostname "$HOST_FQDN"
fi
# Tulis /etc/hosts minimal sehat
cat >/etc/hosts <<EOF
127.0.0.1       localhost
$IP4            $HOST_FQDN $HOST_SHORT
EOF

log "Update sistem & alat bantu…"
export DEBIAN_FRONTEND=noninteractive
apt update
apt -y full-upgrade
ensure_pkg curl wget gnupg ca-certificates apt-transport-https systemd-sysv util-linux ifupdown2 lsb-release

log "Repo Proxmox (no-subscription) & kunci…"
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" \
  > /etc/apt/sources.list.d/pve-install-repo.list
wget -qO /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg \
  https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg
chmod +r /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg
# Matikan repo enterprise jika ada
if [[ -f /etc/apt/sources.list.d/pve-enterprise.list ]]; then
  sed -i 's|^deb |# deb |' /etc/apt/sources.list.d/pve-enterprise.list || true
fi
apt update

log "Install kernel & paket Proxmox… (posfix=Local only)"
echo "postfix postfix/main_mailer_type select Local only" | debconf-set-selections
echo "postfix postfix/mailname string ${HOST_FQDN}"       | debconf-set-selections
apt -y install proxmox-ve postfix open-iscsi

log "Hapus kernel Debian lama (opsional)…"
apt -y remove linux-image-amd64 'linux-image-6.*-amd64' || true

log "Siapkan bridge vmbr0 (IP host dipindah ke bridge)…"
cp -a /etc/network/interfaces /etc/network/interfaces.bak.$(date +%s) 2>/dev/null || true
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
# Tambahkan DNS jika diketahui (opsional, untuk resolver klasik)
if [[ -n "${DNS:-}" && -f /etc/resolv.conf && ! -L /etc/resolv.conf ]]; then
  echo "nameserver $DNS" >/etc/resolv.conf || true
fi

log "Perapihan single-node cluster…"
systemctl stop pve-cluster || true
rm -rf /etc/corosync/* 2>/dev/null || true
umount /etc/pve 2>/dev/null || true
systemctl start pve-cluster
systemctl enable pve-cluster

log "Restart networking & layanan Proxmox…"
systemctl restart networking || true
systemctl restart pve-cluster pvedaemon pveproxy pvestatd || true
systemctl enable  pvedaemon pveproxy pvestatd || true

# -------- Summary --------
echo
log "Ringkasan:"
echo "  Hostname     : $(hostname -f)  (short: $HOST_SHORT)"
echo "  NIC / IP     : $MAIN_IF / $IP4/$PREFIX (gw: $GATE)"
echo "  Kernel aktif : $(uname -r)  (PVE? $(uname -r | grep -q pve && echo YA || echo TIDAK))"
echo
systemctl --no-pager --plain status pve-cluster pvedaemon pveproxy pvestatd | sed -n '1,40p'
echo
log "WebUI: https://$IP4:8006   (user: root, pass: password root Debian)"
warn "Jika WebUI belum bisa diakses, lakukan reboot sekali:  reboot"