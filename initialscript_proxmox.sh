#!/usr/bin/env bash
set -euo pipefail

log(){ printf "\n\033[1;32m[%s]\033[0m %s\n" "$(date +%H:%M:%S)" "$*"; }
warn(){ printf "\n\033[1;33m[WARN]\033[0m %s\n" "$*"; }
die(){ printf "\n\033[1;31m[ERR]\033[0m %s\n" "$*"; exit 1; }

[[ $EUID -eq 0 ]] || die "Jalankan sebagai root (sudo -i)."
grep -qi "bookworm" /etc/os-release || warn "Skrip ini ditulis untuk Debian 12 (Bookworm)."

# ---------- MATIKAN REPO ENTERPRISE DULU ----------
log "Menonaktifkan repo Proxmox enterprise (jika ada)…"
for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null; do
  [[ -f "$f" ]] || continue
  sed -i -E 's|^([[:space:]]*)deb ([^#]*enterprise\.proxmox\.com[^#]*)|# \1deb \2|g' "$f" || true
  sed -i -E 's|^([[:space:]]*)deb ([^#]*pve-enterprise[^#]*)|# \1deb \2|g' "$f" || true
done
# ---------------------------------------------------

# Helpers
prefix_to_netmask(){ local p=$1; local m=(); for _ in 1 2 3 4; do local n=$(( p>=8?255:(p<=0?0:(256-2**(8-p))) )); m+=($n); p=$((p-8)); done; echo "${m[0]}.${m[1]}.${m[2]}.${m[3]}"; }
detect_if(){ ip -4 route list default | awk '{print $5}' | head -n1; }
detect_cidr(){ ip -4 addr show dev "$1" | awk '/inet /{print $2}' | head -n1; }
detect_gw(){ ip -4 route list default | awk '{print $3}' | head -n1; }
ensure_pkg(){ apt-get -y install "$@" >/dev/null 2>&1 || apt -y install "$@"; }

# NIC/IP
log "Deteksi NIC & IP…"
MAIN_IF=$(detect_if); [[ -n "${MAIN_IF:-}" ]] || die "Tidak menemukan NIC default route."
CIDR=$(detect_cidr "$MAIN_IF"); [[ -n "${CIDR:-}" ]] || die "Tidak menemukan IPv4 pada $MAIN_IF."
IP4="${CIDR%/*}"; PREFIX="${CIDR#*/}"; NETMASK=$(prefix_to_netmask "$PREFIX"); GATE=$(detect_gw) || die "Gateway tidak ditemukan"
DNS=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null || true)

# Hostname/FQDN
log "Hostname & FQDN…"
CUR_SHORT=$(hostnamectl --static)
CUR_FQDN=$(hostname -f 2>/dev/null || echo "$CUR_SHORT")
if [[ "$CUR_FQDN" == *.* ]]; then
  HOST_FQDN="$CUR_FQDN"; HOST_SHORT="${CUR_SHORT%%.*}"
else
  HOST_FQDN="pve.local"; HOST_SHORT="pve"
  warn "Hostname belum FQDN → set ke $HOST_FQDN"
  hostnamectl set-hostname "$HOST_FQDN"
fi
cat >/etc/hosts <<EOF
127.0.0.1       localhost
$IP4            $HOST_FQDN $HOST_SHORT
EOF

# Repo/keys & update
log "Install alat bantu & update awal…"
export DEBIAN_FRONTEND=noninteractive
apt update
apt -y full-upgrade
ensure_pkg curl wget gnupg ca-certificates apt-transport-https systemd-sysv util-linux ifupdown2

log "Tambahkan repo Proxmox (no-subscription) & kunci…"
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" \
  > /etc/apt/sources.list.d/pve-install-repo.list
wget -qO /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg \
  https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg
chmod +r /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg
apt update

# Install PVE
log "Install Proxmox VE (postfix=Local only)…"
echo "postfix postfix/main_mailer_type select Local only" | debconf-set-selections
echo "postfix postfix/mailname string ${HOST_FQDN}"       | debconf-set-selections
apt -y install proxmox-ve postfix open-iscsi

log "Hapus kernel Debian lama (opsional)…"
apt -y remove linux-image-amd64 'linux-image-6.*-amd64' || true

# Network bridge
log "Konfigurasi bridge vmbr0 (IP host dipindah ke bridge)…"
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

# Single-node cluster tidy
log "Perapihan cluster single-node…"
systemctl stop pve-cluster || true
rm -rf /etc/corosync/* 2>/dev/null || true
umount /etc/pve 2>/dev/null || true
systemctl start pve-cluster
systemctl enable pve-cluster

log "Restart networking & layanan Proxmox…"
systemctl restart networking || true
systemctl restart pve-cluster pvedaemon pveproxy pvestatd || true
systemctl enable  pvedaemon pveproxy pvestatd || true

# Ringkasan
echo
log "Ringkasan:"
echo "  Hostname     : $(hostname -f)  (short: $HOST_SHORT)"
echo "  NIC / IP     : $MAIN_IF / $IP4/$PREFIX (gw: $GATE)"
echo "  Kernel aktif : $(uname -r)  (PVE? $(uname -r | grep -q pve && echo YA || echo TIDAK))"
echo
systemctl --no-pager --plain status pve-cluster pvedaemon pveproxy pvestatd | sed -n '1,40p'
echo
log "WebUI: https://$IP4:8006  (user: root, pass: password root Debian)"
warn "Jika WebUI belum bisa, lakukan reboot sekali:  reboot"