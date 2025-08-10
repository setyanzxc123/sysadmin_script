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
    m+=("$n"); p=$((p-8)); done; printf "%s.%s.%s.%s" "${m[@]}"
}
detect_if(){ ip -4 route list default | awk '{print $5}' | head -n1; }
detect_cidr(){ ip -4 addr show dev "$1" | awk '/inet /{print $2}' | head -n1; }
detect_gw(){ ip -4 route list default | awk '{print $3}' | head -n1; }

must_ping(){
  ping -c1 -W2 8.8.8.8 >/dev/null 2>&1
}

[[ $EUID -eq 0 ]] || die "Jalankan sebagai root: sudo -i atau sudo bash $0"
grep -qi "bookworm" /etc/os-release || warn "Skrip ini dibuat untuk Debian 12 (Bookworm)."

# ===== Nonaktifkan repo enterprise lebih dulu =====
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
WIRELESS="NO"; is_wireless "$MAIN_IF" && WIRELESS="YES"
log "Interface: $MAIN_IF (Wi-Fi? $WIRELESS)  IP: $IP4/$PREFIX  GW: $GATE"
must_ping || warn "Koneksi internet belum OK, lanjut tapi pastikan koneksi aktif."

# ===== Hostname & hosts (FQDN) =====
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

# ===== Update & tools =====
log "Update sistem & pasang alat bantu…"
export DEBIAN_FRONTEND=noninteractive
apt update
apt -y full-upgrade
ensure_pkg curl wget gnupg ca-certificates apt-transport-https systemd-sysv util-linux ifupdown2 lsb-release

# ===== Repo Proxmox no-subscription =====
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

# ===== Backup & konfigurasi jaringan =====
[[ -f /etc/network/interfaces ]] && BK="/etc/network/interfaces.bak.$(date +%s)" && cp -a /etc/network/interfaces "$BK" && log "Backup network: $BK"

if [[ "$WIRELESS" == "NO" ]]; then
  # --- MODE KABEL: bridge langsung (pindah IP host ke vmbr0) ---
  log "MODE KABEL: pindah IP host ke bridge vmbr0…"
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

  systemctl restart networking || true
  sleep 2
  if ! must_ping; then
    warn "Internet host gagal setelah bridging. Rollback ke $BK…"
    [[ -n "${BK:-}" ]] && cp -a "$BK" /etc/network/interfaces
    systemctl restart networking || true
    die "Rollback selesai. Periksa nama NIC/gateway di file interfaces."
  fi
  log "Host online ✅ (mode bridged)."

else
  # --- MODE WI-FI: vmbr0 dummy + NAT, tidak menyentuh koneksi host ---
  log "MODE WI-FI: biarkan $MAIN_IF DHCP; buat vmbr0 dummy + NAT untuk VM…"
  VM_NET="192.168.100.0/24"; VM_BR_IP="192.168.100.1"; VM_NETMASK="255.255.255.0"

  # Tambahkan vmbr0 jika belum ada
  if ! grep -q '^auto vmbr0' /etc/network/interfaces 2>/dev/null; then
    cat >>/etc/network/interfaces <<EOF

# === PVE vmbr0 (dummy, NAT untuk VM) ===
auto vmbr0
iface vmbr0 inet static
    address $VM_BR_IP
    netmask $VM_NETMASK
    bridge-ports none
    bridge-stp off
    bridge-fd 0
EOF
  fi

  systemctl restart networking || true
  sleep 2
  if ! must_ping; then
    warn "Koneksi host putus setelah menambah vmbr0 (harusnya tidak). Rollback…"