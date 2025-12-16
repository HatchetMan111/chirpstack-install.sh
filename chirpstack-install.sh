#!/usr/bin/env bash
#
# Script Name: ChirpStack V4 Installer for Proxmox VE (LXC)
# Author: Gemini (inspired by Proxmox Helper Scripts)
# Date: 2025-12-16
# Description: Creates a Debian 12 (Bookworm) LXC container and installs ChirpStack V4.
# GitHub: [Ihr GitHub-Repository-Link hier]

# --- Variablen und Konfiguration ---
LXC_TEMPLATE_URL="https://community-templates.github.io/templates/debian-12-standard_12.5-1_amd64.tar.zst"
LXC_TEMPLATE_NAME="debian-12-standard"
LXC_STORAGE="local-lvm" # Passt den Storage-Namen an Ihren Proxmox-Server an
LXC_VETH_BRIDGE="vmbr0" # Passt die Bridge an Ihre Proxmox-Konfiguration an
LXC_CID_DEFAULT=900
LXC_HOSTNAME_DEFAULT="chirpstack"
LXC_RAM_DEFAULT=1024
LXC_CPU_DEFAULT=2
LXC_DISK_DEFAULT=8

# --- Farben und Formatierung ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# --- Funktionen ---

function check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Fehler: Dieses Skript muss als root ausgeführt werden.${NC}"
        exit 1
    fi
}

function prompt_for_config() {
    echo -e "${YELLOW}--- ChirpStack LXC Konfiguration ---${NC}"

    # LXC Container ID
    read -rp "LXC Container ID (Standard: $LXC_CID_DEFAULT): " LXC_CID
    LXC_CID=${LXC_CID:-$LXC_CID_DEFAULT}

    # Hostname
    read -rp "Hostname (Standard: $LXC_HOSTNAME_DEFAULT): " LXC_HOSTNAME
    LXC_HOSTNAME=${LXC_HOSTNAME:-$LXC_HOSTNAME_DEFAULT}

    # Storage
    echo -e "Verfügbare Storages:"
    pvesm status -content rootdir | awk 'NR>1 {print $1}'
    read -rp "Storage (Standard: $LXC_STORAGE): " LXC_STORAGE_USER
    LXC_STORAGE=${LXC_STORAGE_USER:-$LXC_STORAGE}
    
    # Ressourcen
    read -rp "Speichergröße in GB (Standard: $LXC_DISK_DEFAULT): " LXC_DISK
    LXC_DISK=${LXC_DISK:-$LXC_DISK_DEFAULT}
    read -rp "Arbeitsspeicher in MB (Standard: $LXC_RAM_DEFAULT): " LXC_RAM
    LXC_RAM=${LXC_RAM:-$LXC_RAM_DEFAULT}
    read -rp "CPU-Kerne (Standard: $LXC_CPU_DEFAULT): " LXC_CPU
    LXC_CPU=${LXC_CPU:-$LXC_CPU_DEFAULT}

    # Netzwerk
    read -rp "Netzwerk-Bridge (Standard: $LXC_VETH_BRIDGE): " LXC_VETH_BRIDGE_USER
    LXC_VETH_BRIDGE=${LXC_VETH_BRIDGE_USER:-$LXC_VETH_BRIDGE}
    read -rp "Statische IP (z.B. 192.168.1.100/24 oder 'dhcp'): " LXC_IP
    read -rp "Gateway IP (Erforderlich bei statischer IP): " LXC_GATEWAY

    # Zusammenfassung
    echo -e "${GREEN}--- Zusammenfassung ---${NC}"
    echo "Container ID: $LXC_CID"
    echo "Hostname: $LXC_HOSTNAME"
    echo "Storage: $LXC_STORAGE"
    echo "IP-Adresse: $LXC_IP"
    echo "-----------------------"
    read -rp "Bestätigen Sie die Konfiguration (j/n)? " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Jj]$ ]]; then
        echo -e "${RED}Installation abgebrochen.${NC}"
        exit 1
    fi
}

function download_template() {
    echo -e "${GREEN}Lade LXC-Template herunter...${NC}"
    pveam available --section system | grep $LXC_TEMPLATE_NAME >/dev/null
    if [ $? -ne 0 ]; then
        echo -e "${YELLOW}Template nicht gefunden. Versuche Download von extern...${NC}"
        # Alternative Download-Methode, falls nicht in den Standard-Repos
        pveam download $LXC_STORAGE $LXC_TEMPLATE_URL || {
            echo -e "${RED}Fehler beim Herunterladen des Templates.${NC}"
            exit 1
        }
    fi
}

function create_lxc() {
    echo -e "${GREEN}Erstelle LXC Container $LXC_CID (${LXC_HOSTNAME})...${NC}"

    pct create $LXC_CID $LXC_STORAGE:vztmpl/$LXC_TEMPLATE_NAME.tar.zst \
        --hostname $LXC_HOSTNAME \
        --cores $LXC_CPU \
        --memory $LXC_RAM \
        --rootfs $LXC_STORAGE:$LXC_DISK \
        --swap 0 \
        --unprivileged 0 \
        --net0 name=eth0,bridge=$LXC_VETH_BRIDGE,ip=$LXC_IP,gw=$LXC_GATEWAY,type=veth \
        --features nesting=1 \
        --ostype debian

    if [ $? -ne 0 ]; then
        echo -e "${RED}Fehler bei der Erstellung des Containers.${NC}"
        exit 1
    fi

    # Setze Root-Passwort und starte Container
    pct set $LXC_CID --password 'proxmox' # Bitte ändern Sie dieses Standardpasswort
    pct start $LXC_CID

    # Warte auf Start und IP-Zuweisung
    echo -e "${YELLOW}Warte, bis der Container gestartet ist...${NC}"
    sleep 10
}

function install_chirpstack() {
    echo -e "${GREEN}Starte ChirpStack Installation im Container...${NC}"

    # Alle Installationsbefehle als einzelne pct exec-Befehle
    # 1. Update und Abhängigkeiten
    pct exec $LXC_CID -- bash -c "apt update && apt upgrade -y"
    pct exec $LXC_CID -- bash -c "apt install -y wget curl gnupg postgresql postgresql-contrib redis-server"

    # 2. ChirpStack Repository hinzufügen (Debian)
    pct exec $LXC_CID -- bash -c "mkdir -p /etc/apt/keyrings/"
    pct exec $LXC_CID -- bash -c "wget -q -O - https://artifacts.chirpstack.io/packages/chirpstack.key | gpg --dearmor > /etc/apt/keyrings/chirpstack.gpg"
    pct exec $LXC_CID -- bash -c "echo \"deb [signed-by=/etc/apt/keyrings/chirpstack.gpg] https://artifacts.chirpstack.io/packages/4.x/deb stable main\" | tee /etc/apt/sources.list.d/chirpstack.list"
    pct exec $LXC_CID -- bash -c "apt update"

    # 3. ChirpStack und Mosquitto installieren (Mosquitto ist oft hilfreich)
    pct exec $LXC_CID -- bash -c "apt install -y chirpstack mosquitto"

    # 4. PostgreSQL Konfiguration (DB und User erstellen)
    # Wichtig: ChirpStack erfordert oft spezifische Konfigurationsschritte für PostgreSQL/Redis,
    # die hier stark vereinfacht sind. Dies sollte in einer echten Version detaillierter sein!
    pct exec $LXC_CID -- bash -c "sudo -u postgres psql -c \"CREATE USER chirpstack WITH PASSWORD 'dbpassword';\""
    pct exec $LXC_CID -- bash -c "sudo -u postgres psql -c \"CREATE DATABASE chirpstack WITH OWNER chirpstack;\""

    # 5. ChirpStack Konfigurationsanpassung (Beispiel für DB-Verbindung)
    # Ersetzen Sie 'dbpassword' durch das tatsächliche Passwort.
    pct exec $LXC_CID -- bash -c "sed -i 's/^dsn=\/.*$/dsn=\"postgres:\/\/chirpstack:dbpassword@localhost\/chirpstack?sslmode=disable\"/' /etc/chirpstack/chirpstack.toml"

    # 6. Dienste starten
    pct exec $LXC_CID -- bash -c "systemctl enable postgresql redis chirpstack mosquitto"
    pct exec $LXC_CID -- bash -c "systemctl start postgresql redis chirpstack mosquitto"

    echo -e "${GREEN}Installation von ChirpStack V4 abgeschlossen!${NC}"
}

function finish_message() {
    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN}🎉 ChirpStack V4 ist in Container $LXC_CID installiert!${NC}"
    echo -e "${GREEN}Hostname: $LXC_HOSTNAME${NC}"
    echo -e "${GREEN}IP-Adresse: $LXC_IP${NC}"
    echo -e "${GREEN}Weboberfläche (Standard): http://$LXC_IP:8080${NC}"
    echo -e "${YELLOW}Bitte passen Sie die ChirpStack Konfiguration (/etc/chirpstack/chirpstack.toml) an, insbesondere die Zugangsdaten und die MQTT-Einstellungen.${NC}"
    echo -e "${GREEN}================================================================${NC}"
}

# --- Hauptlogik ---
check_root
prompt_for_config
download_template
create_lxc
install_chirpstack
finish_message

# --- Ende des Skripts ---
