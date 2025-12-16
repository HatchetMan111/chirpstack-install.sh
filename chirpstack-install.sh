#!/usr/bin/env bash
set -e

###############################################################################
# ChirpStack V4 Installer for Proxmox VE (LXC, Debian 12)
# Storage:
#   - Templates: local (vztmpl)
#   - RootFS:    local-lvm (rootdir)
###############################################################################

# ------------------ Konfiguration ------------------
LXC_TEMPLATE_STORAGE="local"
LXC_STORAGE="local-lvm"
LXC_TEMPLATE_NAME="debian-12-standard_12.5-1_amd64"

LXC_CID_DEFAULT=900
LXC_HOSTNAME_DEFAULT="chirpstack"
LXC_RAM_DEFAULT=1024
LXC_CPU_DEFAULT=2
LXC_DISK_DEFAULT=8

LXC_BRIDGE="vmbr0"
NET_CONFIG="ip=dhcp"

DB_PASS="dbpassword"

# ------------------ Farben ------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# ------------------ Checks ------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Dieses Skript muss als root ausgeführt werden.${NC}"
        exit 1
    fi
}

check_storage() {
    if ! pvesm status --enabled | grep -q "^${LXC_TEMPLATE_STORAGE} .* vztmpl"; then
        echo -e "${RED}Storage '${LXC_TEMPLATE_STORAGE}' unterstützt kein 'vztmpl'.${NC}"
        exit 1
    fi

    if ! pvesm status --enabled | grep -q "^${LXC_STORAGE} .* rootdir"; then
        echo -e "${RED}Storage '${LXC_STORAGE}' unterstützt kein 'rootdir'.${NC}"
        exit 1
    fi
}

# ------------------ Benutzerabfrage ------------------
prompt_config() {
    echo -e "${YELLOW}--- ChirpStack LXC Konfiguration ---${NC}"

    read -rp "Container ID [${LXC_CID_DEFAULT}]: " LXC_CID
    LXC_CID=${LXC_CID:-$LXC_CID_DEFAULT}

    if pct status "$LXC_CID" &>/dev/null; then
        echo -e "${RED}Container ID ${LXC_CID} existiert bereits.${NC}"
        exit 1
    fi

    read -rp "Hostname [${LXC_HOSTNAME_DEFAULT}]: " LXC_HOSTNAME
    LXC_HOSTNAME=${LXC_HOSTNAME:-$LXC_HOSTNAME_DEFAULT}

    read -rp "Disk (GB) [${LXC_DISK_DEFAULT}]: " LXC_DISK
    LXC_DISK=${LXC_DISK:-$LXC_DISK_DEFAULT}

    read -rp "RAM (MB) [${LXC_RAM_DEFAULT}]: " LXC_RAM
    LXC_RAM=${LXC_RAM:-$LXC_RAM_DEFAULT}

    read -rp "CPU Cores [${LXC_CPU_DEFAULT}]: " LXC_CPU
    LXC_CPU=${LXC_CPU:-$LXC_CPU_DEFAULT}

    echo
    echo -e "${GREEN}Zusammenfassung:${NC}"
    echo "  ID:        $LXC_CID"
    echo "  Hostname:  $LXC_HOSTNAME"
    echo "  CPU:       $LXC_CPU"
    echo "  RAM:       $LXC_RAM MB"
    echo "  Disk:      $LXC_DISK GB"
    echo "  Template:  $LXC_TEMPLATE_NAME"
    echo

    read -rp "Installation starten? (j/n): " -n 1 REPLY
    echo
    [[ $REPLY =~ ^[Jj]$ ]] || exit 0
}

# ------------------ Template ------------------
download_template() {
    echo -e "${GREEN}Prüfe LXC-Template...${NC}"
    pveam update

    if ! pveam list "$LXC_TEMPLATE_STORAGE" | grep -q "$LXC_TEMPLATE_NAME"; then
        echo -e "${YELLOW}Template wird heruntergeladen...${NC}"
        pveam download "$LXC_TEMPLATE_STORAGE" "${LXC_TEMPLATE_NAME}.tar.zst"
    else
        echo -e "${GREEN}Template bereits vorhanden.${NC}"
    fi
}

# ------------------ LXC erstellen ------------------
create_lxc() {
    echo -e "${GREEN}Erstelle Container $LXC_CID...${NC}"

    pct create "$LXC_CID" \
        "${LXC_TEMPLATE_STORAGE}:vztmpl/${LXC_TEMPLATE_NAME}.tar.zst" \
        --hostname "$LXC_HOSTNAME" \
        --cores "$LXC_CPU" \
        --memory "$LXC_RAM" \
        --rootfs "${LXC_STORAGE}:${LXC_DISK}" \
        --swap 0 \
        --net0 "name=eth0,bridge=${LXC_BRIDGE},${NET_CONFIG}" \
        --ostype debian \
        --unprivileged 0 \
        --features nesting=1 \
        --onboot 1 \
        --start 1

    echo -e "${YELLOW}Warte auf DHCP...${NC}"
    sleep 15
}

# ------------------ ChirpStack ------------------
install_chirpstack() {
    echo -e "${GREEN}Installiere ChirpStack...${NC}"

    pct exec "$LXC_CID" -- bash -c "
        apt update &&
        apt upgrade -y &&
        apt install -y wget curl gnupg postgresql redis-server mosquitto
    "

    pct exec "$LXC_CID" -- bash -c "
        mkdir -p /etc/apt/keyrings &&
        wget -qO- https://artifacts.chirpstack.io/packages/chirpstack.key |
        gpg --dearmor > /etc/apt/keyrings/chirpstack.gpg
    "

    pct exec "$LXC_CID" -- bash -c "
        echo 'deb [signed-by=/etc/apt/keyrings/chirpstack.gpg] \
        https://artifacts.chirpstack.io/packages/4.x/deb stable main' \
        > /etc/apt/sources.list.d/chirpstack.list
    "

    pct exec "$LXC_CID" -- bash -c "
        apt update &&
        apt install -y chirpstack
    "

    pct exec "$LXC_CID" -- bash -c "
        sudo -u postgres psql <<EOF
CREATE USER chirpstack WITH PASSWORD '${DB_PASS}';
CREATE DATABASE chirpstack OWNER chirpstack;
EOF
    "

    pct exec "$LXC_CID" -- bash -c "
        sed -i \"s|^dsn =.*|dsn = 'postgres://chirpstack:${DB_PASS}@localhost/chirpstack?sslmode=disable'|\" \
        /etc/chirpstack/chirpstack.toml
    "

    pct exec "$LXC_CID" -- bash -c "
        systemctl enable postgresql redis-server mosquitto chirpstack &&
        systemctl restart postgresql redis-server mosquitto chirpstack
    "
}

# ------------------ Abschluss ------------------
finish() {
    IP=$(pct exec "$LXC_CID" -- ip -4 addr show eth0 | awk '/inet /{print $2}' | cut -d/ -f1)

    echo -e "${GREEN}=================================================${NC}"
    echo -e "${GREEN}🎉 ChirpStack erfolgreich installiert!${NC}"
    echo -e "${GREEN}Container ID: $LXC_CID${NC}"
    echo -e "${GREEN}IP-Adresse:   $IP${NC}"
    echo -e "${GREEN}Web UI:       http://$IP:8080${NC}"
    echo -e "${YELLOW}Login: admin / admin${NC}"
    echo -e "${YELLOW}DB Passwort: ${DB_PASS}${NC}"
    echo -e "${GREEN}=================================================${NC}"
}

# ------------------ Main ------------------
check_root
check_storage
prompt_config
download_template
create_lxc
install_chirpstack
finish
