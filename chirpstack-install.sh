#!/usr/bin/env bash
set -e

### ---------------- Konfiguration ----------------
LXC_TEMPLATE_NAME="debian-12-standard_12.5-1_amd64"
LXC_ROOTFS_STORAGE="local-lvm"   # RootFS bleibt fest
LXC_CID_DEFAULT=900
LXC_HOSTNAME_DEFAULT="chirpstack"
LXC_RAM_DEFAULT=1024
LXC_CPU_DEFAULT=2
LXC_DISK_DEFAULT=8
LXC_BRIDGE="vmbr0"
DB_PASS="dbpassword"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

### ---------------- Checks ----------------
[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }

### ---------------- Template Storage automatisch finden ----------------
echo -e "${GREEN}Suche Storage mit 'vztmpl'...${NC}"

TEMPLATE_STORAGE=$(pvesm status --enabled | awk '$4 ~ /vztmpl/ {print $1; exit}')

if [[ -z "$TEMPLATE_STORAGE" ]]; then
    echo -e "${RED}Kein Storage mit 'vztmpl' gefunden!${NC}"
    echo -e "${YELLOW}Lege z.B. einen Directory-Storage an:${NC}"
    echo "pvesm add dir local --path /var/lib/vz --content vztmpl"
    exit 1
fi

echo -e "${GREEN}Verwende Template-Storage: $TEMPLATE_STORAGE${NC}"

### ---------------- User Input ----------------
read -rp "Container ID [$LXC_CID_DEFAULT]: " LXC_CID
LXC_CID=${LXC_CID:-$LXC_CID_DEFAULT}
pct status "$LXC_CID" &>/dev/null && { echo "CID existiert"; exit 1; }

read -rp "Hostname [$LXC_HOSTNAME_DEFAULT]: " LXC_HOSTNAME
LXC_HOSTNAME=${LXC_HOSTNAME:-$LXC_HOSTNAME_DEFAULT}

read -rp "Disk GB [$LXC_DISK_DEFAULT]: " LXC_DISK
LXC_DISK=${LXC_DISK:-$LXC_DISK_DEFAULT}

read -rp "RAM MB [$LXC_RAM_DEFAULT]: " LXC_RAM
LXC_RAM=${LXC_RAM:-$LXC_RAM_DEFAULT}

read -rp "CPU [$LXC_CPU_DEFAULT]: " LXC_CPU
LXC_CPU=${LXC_CPU:-$LXC_CPU_DEFAULT}

read -rp "Installation starten? (j/n): " -n1 OK
echo
[[ $OK =~ [Jj] ]] || exit 0

### ---------------- Template ----------------
pveam update
if ! pveam list "$TEMPLATE_STORAGE" | grep -q "$LXC_TEMPLATE_NAME"; then
    pveam download "$TEMPLATE_STORAGE" "${LXC_TEMPLATE_NAME}.tar.zst"
fi

### ---------------- Container ----------------
pct create "$LXC_CID" \
  "$TEMPLATE_STORAGE:vztmpl/${LXC_TEMPLATE_NAME}.tar.zst" \
  --hostname "$LXC_HOSTNAME" \
  --cores "$LXC_CPU" \
  --memory "$LXC_RAM" \
  --rootfs "$LXC_ROOTFS_STORAGE:$LXC_DISK" \
  --net0 name=eth0,bridge=$LXC_BRIDGE,ip=dhcp \
  --ostype debian \
  --features nesting=1 \
  --onboot 1 \
  --start 1

sleep 15

### ---------------- ChirpStack ----------------
pct exec "$LXC_CID" -- bash -c "
apt update &&
apt install -y wget gnupg postgresql redis-server mosquitto
"

pct exec "$LXC_CID" -- bash -c "
mkdir -p /etc/apt/keyrings &&
wget -qO- https://artifacts.chirpstack.io/packages/chirpstack.key |
gpg --dearmor > /etc/apt/keyrings/chirpstack.gpg
"

pct exec "$LXC_CID" -- bash -c "
echo 'deb [signed-by=/etc/apt/keyrings/chirpstack.gpg] https://artifacts.chirpstack.io/packages/4.x/deb stable main' \
> /etc/apt/sources.list.d/chirpstack.list
apt update && apt install -y chirpstack
"

pct exec "$LXC_CID" -- bash -c "
sudo -u postgres psql -c \"CREATE USER chirpstack WITH PASSWORD '$DB_PASS';\"
sudo -u postgres psql -c \"CREATE DATABASE chirpstack OWNER chirpstack;\"
"

pct exec "$LXC_CID" -- bash -c "
sed -i \"s|^dsn =.*|dsn = 'postgres://chirpstack:$DB_PASS@localhost/chirpstack?sslmode=disable'|\" \
/etc/chirpstack/chirpstack.toml
systemctl enable chirpstack postgresql redis-server mosquitto
systemctl restart chirpstack
"

IP=$(pct exec "$LXC_CID" -- ip -4 a show eth0 | awk '/inet/{print $2}' | cut -d/ -f1)

echo -e "${GREEN}FERTIG! Web UI: http://$IP:8080${NC}"
