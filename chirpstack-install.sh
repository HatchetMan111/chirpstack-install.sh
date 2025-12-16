#!/usr/bin/env bash
#
# Script Name: ChirpStack V4 Installer for Proxmox VE (LXC - Fixed Storage/DHCP)
# Author: Gemini (inspired by Proxmox Helper Scripts)
# Date: 2025-12-16
# Description: Creates a Debian 12 (Bookworm) LXC container and installs ChirpStack V4.
#              Uses 'local' for Template storage and 'local-lvm' for LXC RootFS.
# GitHub: https://github.com/HatchetMan111/chirpstack-install.sh

# --- Variablen und Konfiguration ---
LXC_TEMPLATE_URL="https://community-templates.github.io/templates/debian-12-standard_12.5-1_amd64.tar.zst"
LXC_TEMPLATE_NAME="debian-12-standard"
DB_PASS="dbpassword" 
LXC_CID_DEFAULT=900
LXC_HOSTNAME_DEFAULT="chirpstack"
LXC_RAM_DEFAULT=1024
LXC_CPU_DEFAULT=2
LXC_DISK_DEFAULT=8

# STANDARDS: local-lvm für die Root-Disk, local für Templates
LXC_STORAGE="local-lvm"      # <-- Container RootFS (braucht rootdir)
LXC_TEMPLATE_STORAGE="local" # <-- Template (braucht vztmpl)
LXC_VETH_BRIDGE="vmbr0"
NET_CONFIG="ip=dhcp"    
LXC_IP="dhcp"           

# --- Farben und Formatierung ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# --- Funktionen ---

function check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Fehler: Dieses Skript muss als root ausgeführt werden.${NC}"
        exit 1
    fi
}

function check_fixed_storage() {
    # 1. Prüfe, ob LXC_STORAGE (local-lvm) rootdir unterstützt
    if ! pvesm status --enabled 1 2>/dev/null | grep -E "^$LXC_STORAGE\s" | awk '{print $4}' | grep -q 'rootdir'; then
        echo -e "${RED}Fehler: Der RootFS-Storage '$LXC_STORAGE' existiert nicht, ist inaktiv oder unterstützt nicht 'rootdir'.${NC}"
        exit 1
    fi
    # 2. Prüfe, ob LXC_TEMPLATE_STORAGE (local) vztmpl unterstützt
    if ! pvesm status --enabled 1 2>/dev/null | grep -E "^$LXC_TEMPLATE_STORAGE\s" | awk '{print $4}' | grep -q 'vztmpl'; then
        echo -e "${RED}Fehler: Der Template-Storage '$LXC_TEMPLATE_STORAGE' existiert nicht, ist inaktiv oder unterstützt nicht 'vztmpl'.${NC}"
        echo -e "${YELLOW}Hinweis: Templates müssen auf einem Verzeichnis-Storage (wie 'local') gespeichert werden.${NC}"
        exit 1
    fi
}

function prompt_for_config() {
    echo -e "${YELLOW}--- ChirpStack LXC Konfiguration ---${NC}"
    echo -e "${GREEN}RootFS: $LXC_STORAGE, Templates: $LXC_TEMPLATE_STORAGE, Netzwerk: DHCP über $LXC_VETH_BRIDGE.${NC}"

    check_fixed_storage # Führt die Prüfung durch

    read -rp "LXC Container ID (Standard: $LXC_CID_DEFAULT): " LXC_CID
    LXC_CID=${LXC_CID:-$LXC_CID_DEFAULT}
    if pct status $LXC_CID &> /dev/null; then
        echo -e "${RED}Fehler: Container ID $LXC_CID ist bereits in Verwendung.${NC}"
        exit 1
    fi

    read -rp "Hostname (Standard: $LXC_HOSTNAME_DEFAULT): " LXC_HOSTNAME
    LXC_HOSTNAME=${LXC_HOSTNAME:-$LXC_HOSTNAME_DEFAULT}

    read -rp "Speichergröße in GB (Standard: $LXC_DISK_DEFAULT): " LXC_DISK
    LXC_DISK=${LXC_DISK:-$LXC_DISK_DEFAULT}
    read -rp "Arbeitsspeicher in MB (Standard: $LXC_RAM_DEFAULT): " LXC_RAM
    LXC_RAM=${LXC_RAM:-$LXC_RAM_DEFAULT}
    read -rp "CPU-Kerne (Standard: $LXC_CPU_DEFAULT): " LXC_CPU
    LXC_CPU=${LXC_CPU:-$LXC_CPU_DEFAULT}
    
    echo -e "${GREEN}--- Zusammenfassung ---${NC}"
    echo "Container ID: $LXC_CID"
    echo "Hostname: $LXC_HOSTNAME"
    echo "RootFS Storage: $LXC_STORAGE"
    echo "IP-Adresse: $LXC_IP (DHCP)"
    echo "Ressourcen: ${LXC_CPU}x CPU, ${LXC_RAM}MB RAM, ${LXC_DISK}GB Disk"
    echo "-----------------------"
    read -rp "Bestätigen Sie die Konfiguration und starten Sie die Installation (j/n)? " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Jj]$ ]]; then
        echo -e "${RED}Installation abgebrochen.${NC}"
        exit 1
    fi
}

function download_template() {
    echo -e "${GREEN}Lade LXC-Template ($LXC_TEMPLATE_NAME) herunter...${NC}"
    
    # Template-Check und Download verwenden den Template-Storage
    pveam list $LXC_TEMPLATE_STORAGE | grep "$LXC_TEMPLATE_NAME" >/dev/null 
    if [ $? -ne 0 ]; then
        echo -e "${YELLOW}Template nicht im Cache gefunden. Lade in '$LXC_TEMPLATE_STORAGE' herunter von: $LXC_TEMPLATE_URL${NC}"
        pveam download $LXC_TEMPLATE_STORAGE $LXC_TEMPLATE_URL || {
            # KORREKTUR: Fehlermeldung verwendet jetzt $LXC_TEMPLATE_STORAGE
            echo -e "${RED}Fehler beim Herunterladen des Templates. Prüfen Sie, ob '$LXC_TEMPLATE_STORAGE' aktiv ist und 'vztmpl' unterstützt.${NC}"
            exit 1
        }
    else
        echo -e "${GREEN}Template ist bereits im Cache vorhanden auf '$LXC_TEMPLATE_STORAGE'.${NC}"
    fi
}

function create_lxc() {
    echo -e "${GREEN}Erstelle LXC Container $LXC_CID (${LXC_HOSTNAME})...${NC}"

    # Template-Pfad verwendet $LXC_TEMPLATE_STORAGE, RootFS verwendet $LXC_STORAGE
    pct create $LXC_CID $LXC_TEMPLATE_STORAGE:vztmpl/$LXC_TEMPLATE_NAME.tar.zst \
        --hostname $LXC_HOSTNAME \
        --cores $LXC_CPU \
        --memory $LXC_RAM \
        --rootfs $LXC_STORAGE:$LXC_DISK \
        --swap 0 \
        --unprivileged 0 \
        --net0 name=eth0,bridge=$LXC_VETH_BRIDGE,$NET_CONFIG,type=veth \
        --features nesting=1 \
        --ostype debian \
        --onboot 1 \
        --start 1

    if [ $? -ne 0 ]; then
        echo -e "${RED}Fehler bei der Erstellung des Containers.${NC}"
        exit 1
    fi

    echo -e "${YELLOW}Warte, bis der Container gestartet ist und eine IP per DHCP zugewiesen wurde (ca. 15s)...${NC}"
    sleep 15
}

function install_chirpstack() {
    echo -e "${GREEN}Starte ChirpStack Installation im Container...${NC}"

    pct exec $LXC_CID -- bash -c "apt update && apt upgrade -y"
    pct exec $LXC_CID -- bash -c "DEBIAN_FRONTEND=noninteractive apt install -y wget curl gnupg postgresql postgresql-contrib redis-server"
    pct exec $LXC_CID -- bash -c "mkdir -p /etc/apt/keyrings/"
    pct exec $LXC_CID -- bash -c "wget -q -O - https://artifacts.chirpstack.io/packages/chirpstack.key | gpg --dearmor > /etc/apt/keyrings/chirpstack.gpg"
    pct exec $LXC_CID -- bash -c "echo \"deb [signed-by=/etc/apt/keyrings/chirpstack.gpg] https://artifacts.chirpstack.io/packages/4.x/deb stable main\" | tee /etc/apt/sources.list.d/chirpstack.list"
    pct exec $LXC_CID -- bash -c "apt update"
    pct exec $LXC_CID -- bash -c "DEBIAN_FRONTEND=noninteractive apt install -y chirpstack mosquitto"
    pct exec $LXC_CID -- bash -c "sudo -u postgres psql -c \"CREATE USER chirpstack WITH PASSWORD '$DB_PASS';\""
    pct exec $LXC_CID -- bash -c "sudo -u postgres psql -c \"CREATE DATABASE chirpstack WITH OWNER chirpstack;\""
    pct exec $LXC_CID -- bash -c "sed -i 's/^dsn=.*$/dsn=\"postgres:\/\/chirpstack:$DB_PASS@localhost\/chirpstack?sslmode=disable\"/' /etc/chirpstack/chirpstack.toml"
    pct exec $LXC_CID -- bash -c "systemctl enable postgresql redis chirpstack mosquitto"
    pct exec $LXC_CID -- bash -c "systemctl start postgresql redis chirpstack mosquitto"

    echo -e "${GREEN}Installation von ChirpStack V4 abgeschlossen!${NC}"
}

function finish_message() {
    ACTUAL_IP=$(pct exec $LXC_CID ip a show eth0 | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)

    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN}🎉 ChirpStack V4 ist in Container $LXC_CID installiert!${NC}"
    echo -e "${GREEN}Hostname: $LXC_HOSTNAME${NC}"
    echo -e "${GREEN}Zugewiesene IP-Adresse: $ACTUAL_IP${NC}"
    echo -e "${GREEN}Weboberfläche (Standard): http://$ACTUAL_IP:8080${NC}"
    echo -e "${YELLOW}--- WICHTIG ---${NC}"
    echo -e "${YELLOW}Das PostgreSQL-Passwort ist '$DB_PASS'. Ändern Sie dies SOFORT im Container!${NC}"
    echo -e "${YELLOW}Login Web UI: admin / admin${NC}"
    echo -e "${GREEN}================================================================${NC}"
}

# --- Hauptlogik ---
check_root
prompt_for_config
download_template
create_lxc
install_chirpstack
finish_message
