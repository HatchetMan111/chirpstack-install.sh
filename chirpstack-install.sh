#!/usr/bin/env bash
#
# Script Name: ChirpStack V4 Installer for Proxmox VE (LXC - Enhanced)
# Author: Enhanced Version
# Date: 2025-12-16
# Description: Creates a Debian 12 (Bookworm) LXC container with automatic storage detection

set -e

# --- Variablen und Konfiguration ---
LXC_TEMPLATE_URL="http://download.proxmox.com/images/system/debian-12-standard_12.7-1_amd64.tar.zst"
LXC_TEMPLATE_NAME="debian-12-standard_12.7-1_amd64.tar.zst"
DB_PASS="dbpassword" 
LXC_CID_DEFAULT=900
LXC_HOSTNAME_DEFAULT="chirpstack"
LXC_RAM_DEFAULT=2048
LXC_CPU_DEFAULT=2
LXC_DISK_DEFAULT=10
LXC_VETH_BRIDGE="vmbr0"
NET_CONFIG="ip=dhcp"    
LXC_IP="dhcp"           

# --- Farben und Formatierung ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Funktionen ---

function print_header() {
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║     ChirpStack V4 Installer für Proxmox VE (LXC)          ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

function check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}❌ Fehler: Dieses Skript muss als root ausgeführt werden.${NC}"
        exit 1
    fi
}

function detect_storages() {
    echo -e "${YELLOW}🔍 Erkenne verfügbare Storages...${NC}"
    
    # Finde Storage für Templates (muss vztmpl Content-Type unterstützen)
    LXC_TEMPLATE_STORAGE=$(pvesm status -content vztmpl | awk 'NR>1 {print $1}' | head -n1)
    
    if [[ -z "$LXC_TEMPLATE_STORAGE" ]]; then
        echo -e "${RED}❌ Kein Storage mit 'vztmpl' Content-Type gefunden!${NC}"
        echo -e "${YELLOW}Verfügbare Storages:${NC}"
        pvesm status
        exit 1
    fi
    
    # Finde Storage für Container (muss rootdir Content-Type unterstützen)
    LXC_STORAGE=$(pvesm status -content rootdir | awk 'NR>1 {print $1}' | head -n1)
    
    if [[ -z "$LXC_STORAGE" ]]; then
        echo -e "${RED}❌ Kein Storage mit 'rootdir' Content-Type gefunden!${NC}"
        echo -e "${YELLOW}Verfügbare Storages:${NC}"
        pvesm status
        exit 1
    fi
    
    echo -e "${GREEN}✓ Template Storage: $LXC_TEMPLATE_STORAGE${NC}"
    echo -e "${GREEN}✓ Container Storage: $LXC_STORAGE${NC}"
    echo ""
}

function check_bridge() {
    if ! ip link show $LXC_VETH_BRIDGE &> /dev/null; then
        echo -e "${YELLOW}⚠ Bridge '$LXC_VETH_BRIDGE' nicht gefunden. Verfügbare Bridges:${NC}"
        ip link show | grep -E "^[0-9]+: vmbr" | awk '{print $2}' | sed 's/:$//'
        read -rp "Bridge-Name eingeben (oder Enter für $LXC_VETH_BRIDGE): " CUSTOM_BRIDGE
        if [[ -n "$CUSTOM_BRIDGE" ]]; then
            LXC_VETH_BRIDGE="$CUSTOM_BRIDGE"
        fi
    fi
}

function prompt_for_config() {
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}                  Container Konfiguration${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    read -rp "Container ID (Standard: $LXC_CID_DEFAULT): " LXC_CID
    LXC_CID=${LXC_CID:-$LXC_CID_DEFAULT}
    
    if pct status $LXC_CID &> /dev/null; then
        echo -e "${RED}❌ Fehler: Container ID $LXC_CID ist bereits in Verwendung.${NC}"
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
    
    read -rp "Datenbank-Passwort (Standard: $DB_PASS): " CUSTOM_DB_PASS
    if [[ -n "$CUSTOM_DB_PASS" ]]; then
        DB_PASS="$CUSTOM_DB_PASS"
    fi
    
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}                    Zusammenfassung${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  Container ID:        ${BLUE}$LXC_CID${NC}"
    echo -e "  Hostname:            ${BLUE}$LXC_HOSTNAME${NC}"
    echo -e "  Template Storage:    ${BLUE}$LXC_TEMPLATE_STORAGE${NC}"
    echo -e "  Container Storage:   ${BLUE}$LXC_STORAGE${NC}"
    echo -e "  Netzwerk Bridge:     ${BLUE}$LXC_VETH_BRIDGE${NC}"
    echo -e "  IP-Konfiguration:    ${BLUE}$LXC_IP${NC}"
    echo -e "  CPU-Kerne:           ${BLUE}$LXC_CPU${NC}"
    echo -e "  RAM:                 ${BLUE}${LXC_RAM}MB${NC}"
    echo -e "  Festplatte:          ${BLUE}${LXC_DISK}GB${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    read -rp "Installation starten? (j/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[JjYy]$ ]]; then
        echo -e "${RED}Installation abgebrochen.${NC}"
        exit 1
    fi
}

function download_template() {
    echo ""
    echo -e "${GREEN}📥 Lade LXC-Template herunter...${NC}"
    
    TEMPLATE_PATH="$LXC_TEMPLATE_STORAGE:vztmpl/$LXC_TEMPLATE_NAME"
    
    # Prüfe ob Template bereits existiert
    if pvesm list $LXC_TEMPLATE_STORAGE | grep -q "$LXC_TEMPLATE_NAME"; then
        echo -e "${GREEN}✓ Template bereits vorhanden: $LXC_TEMPLATE_NAME${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}⏳ Lade Template von: $LXC_TEMPLATE_URL${NC}"
    
    # Template herunterladen
    cd /var/lib/vz/template/cache 2>/dev/null || mkdir -p /var/lib/vz/template/cache && cd /var/lib/vz/template/cache
    
    wget -q --show-progress "$LXC_TEMPLATE_URL" -O "$LXC_TEMPLATE_NAME" || {
        echo -e "${RED}❌ Fehler beim Download des Templates.${NC}"
        exit 1
    }
    
    echo -e "${GREEN}✓ Template erfolgreich heruntergeladen${NC}"
}

function create_lxc() {
    echo ""
    echo -e "${GREEN}🔧 Erstelle LXC Container $LXC_CID...${NC}"

    TEMPLATE_PATH="$LXC_TEMPLATE_STORAGE:vztmpl/$LXC_TEMPLATE_NAME"
    
    pct create $LXC_CID "$TEMPLATE_PATH" \
        --hostname "$LXC_HOSTNAME" \
        --cores "$LXC_CPU" \
        --memory "$LXC_RAM" \
        --rootfs "$LXC_STORAGE:$LXC_DISK" \
        --swap 512 \
        --unprivileged 1 \
        --net0 "name=eth0,bridge=$LXC_VETH_BRIDGE,$NET_CONFIG,type=veth,firewall=1" \
        --features "nesting=1" \
        --ostype debian \
        --onboot 1 || {
        echo -e "${RED}❌ Fehler bei der Container-Erstellung.${NC}"
        exit 1
    }

    echo -e "${GREEN}✓ Container erstellt${NC}"
    echo -e "${YELLOW}⏳ Starte Container...${NC}"
    
    pct start $LXC_CID || {
        echo -e "${RED}❌ Fehler beim Starten des Containers.${NC}"
        exit 1
    }
    
    echo -e "${YELLOW}⏳ Warte auf Container-Start und DHCP (25s)...${NC}"
    sleep 25
}

function wait_for_network() {
    echo -e "${YELLOW}⏳ Warte auf Netzwerkkonnektivität...${NC}"
    
    for i in {1..30}; do
        if pct exec $LXC_CID -- ping -c1 8.8.8.8 &>/dev/null; then
            echo -e "${GREEN}✓ Netzwerk verfügbar${NC}"
            return 0
        fi
        sleep 2
    done
    
    echo -e "${YELLOW}⚠ Netzwerk-Timeout, fahre trotzdem fort...${NC}"
}

function install_chirpstack() {
    echo ""
    echo -e "${GREEN}📦 Installiere ChirpStack V4...${NC}"
    echo ""

    echo -e "${YELLOW}[1/9] System-Update...${NC}"
    pct exec $LXC_CID -- bash -c "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y" || true
    
    echo -e "${YELLOW}[2/9] Installiere Basis-Pakete...${NC}"
    pct exec $LXC_CID -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y wget curl gnupg2 apt-transport-https ca-certificates"
    
    echo -e "${YELLOW}[3/9] Installiere PostgreSQL und Redis...${NC}"
    pct exec $LXC_CID -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql postgresql-contrib redis-server"
    
    echo -e "${YELLOW}[4/9] Füge ChirpStack Repository hinzu...${NC}"
    # Korrekte URL für den GPG Key
    pct exec $LXC_CID -- bash -c "mkdir -p /etc/apt/keyrings/"
    pct exec $LXC_CID -- bash -c "wget -qO - https://artifacts.chirpstack.io/packages/chirpstack.key | gpg --dearmor > /etc/apt/keyrings/chirpstack.gpg"
    
    echo -e "${YELLOW}[5/9] Füge Repository zur Paketliste hinzu...${NC}"
    pct exec $LXC_CID -- bash -c "echo 'deb [signed-by=/etc/apt/keyrings/chirpstack.gpg] https://artifacts.chirpstack.io/packages/4.x/deb stable main' > /etc/apt/sources.list.d/chirpstack.list"
    
    echo -e "${YELLOW}[6/9] Aktualisiere Paketliste...${NC}"
    pct exec $LXC_CID -- bash -c "apt-get update"
    
    echo -e "${YELLOW}[7/9] Installiere ChirpStack und Mosquitto...${NC}"
    pct exec $LXC_CID -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y chirpstack mosquitto mosquitto-clients"
    
    echo -e "${YELLOW}[8/9] Konfiguriere Datenbank...${NC}"
    # Warte kurz damit PostgreSQL vollständig gestartet ist
    sleep 3
    pct exec $LXC_CID -- bash -c "sudo -u postgres psql -c \"CREATE ROLE chirpstack WITH LOGIN PASSWORD '$DB_PASS';\" 2>/dev/null || true"
    pct exec $LXC_CID -- bash -c "sudo -u postgres psql -c \"CREATE DATABASE chirpstack WITH OWNER chirpstack;\" 2>/dev/null || true"
    pct exec $LXC_CID -- bash -c "sudo -u postgres psql -c \"GRANT ALL PRIVILEGES ON DATABASE chirpstack TO chirpstack;\" 2>/dev/null || true"
    
    echo -e "${YELLOW}[9/9] Konfiguriere ChirpStack...${NC}"
    pct exec $LXC_CID -- bash -c "sed -i 's|^dsn=.*|dsn=\"postgres://chirpstack:$DB_PASS@localhost/chirpstack?sslmode=disable\"|' /etc/chirpstack/chirpstack.toml"
    
    echo -e "${YELLOW}Aktiviere und starte Dienste...${NC}"
    pct exec $LXC_CID -- bash -c "systemctl enable postgresql redis-server chirpstack mosquitto"
    pct exec $LXC_CID -- bash -c "systemctl restart postgresql redis-server"
    sleep 3
    pct exec $LXC_CID -- bash -c "systemctl restart chirpstack mosquitto"
    
    # Warte bis Dienste hochgefahren sind
    sleep 5
    
    echo ""
    echo -e "${GREEN}✓ ChirpStack Installation abgeschlossen!${NC}"
}

function verify_installation() {
    echo ""
    echo -e "${YELLOW}🔍 Überprüfe Installation...${NC}"
    
    sleep 2
    
    if pct exec $LXC_CID -- systemctl is-active --quiet chirpstack; then
        echo -e "${GREEN}✓ ChirpStack läuft${NC}"
    else
        echo -e "${YELLOW}⚠ ChirpStack läuft möglicherweise noch nicht (startet noch...)${NC}"
    fi
    
    if pct exec $LXC_CID -- systemctl is-active --quiet mosquitto; then
        echo -e "${GREEN}✓ Mosquitto läuft${NC}"
    else
        echo -e "${YELLOW}⚠ Mosquitto läuft nicht${NC}"
    fi
    
    if pct exec $LXC_CID -- systemctl is-active --quiet postgresql; then
        echo -e "${GREEN}✓ PostgreSQL läuft${NC}"
    else
        echo -e "${YELLOW}⚠ PostgreSQL läuft nicht${NC}"
    fi
    
    if pct exec $LXC_CID -- systemctl is-active --quiet redis-server; then
        echo -e "${GREEN}✓ Redis läuft${NC}"
    else
        echo -e "${YELLOW}⚠ Redis läuft nicht${NC}"
    fi
}

function finish_message() {
    ACTUAL_IP=$(pct exec $LXC_CID -- ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
    
    if [[ -z "$ACTUAL_IP" ]]; then
        ACTUAL_IP="Keine IP gefunden - bitte mit 'pct exec $LXC_CID ip a' prüfen"
    fi
    
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                  🎉 Installation Erfolgreich!              ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  📦 Container ID:          ${BLUE}$LXC_CID${NC}"
    echo -e "  🏷️  Hostname:              ${BLUE}$LXC_HOSTNAME${NC}"
    echo -e "  🌐 IP-Adresse:            ${BLUE}$ACTUAL_IP${NC}"
    echo -e "  🔗 Web-Interface:         ${BLUE}http://$ACTUAL_IP:8080${NC}"
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}                     Login-Daten${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  Web-UI:     ${BLUE}admin${NC} / ${BLUE}admin${NC}"
    echo -e "  Datenbank:  ${BLUE}chirpstack${NC} / ${BLUE}$DB_PASS${NC}"
    echo ""
    echo -e "${RED}⚠️  WICHTIG: Ändern Sie die Standardpasswörter!${NC}"
    echo ""
    echo -e "${YELLOW}Nützliche Befehle:${NC}"
    echo -e "  ${BLUE}pct enter $LXC_CID${NC}                    # Container betreten"
    echo -e "  ${BLUE}pct stop $LXC_CID${NC}                     # Container stoppen"
    echo -e "  ${BLUE}pct start $LXC_CID${NC}                    # Container starten"
    echo -e "  ${BLUE}pct exec $LXC_CID systemctl status chirpstack${NC}  # Status prüfen"
    echo ""
    echo -e "${YELLOW}Im Container (nach 'pct enter $LXC_CID'):${NC}"
    echo -e "  ${BLUE}journalctl -u chirpstack -f${NC}           # ChirpStack Logs"
    echo -e "  ${BLUE}systemctl restart chirpstack${NC}          # ChirpStack neustarten"
    echo -e "  ${BLUE}nano /etc/chirpstack/chirpstack.toml${NC}  # Konfiguration bearbeiten"
    echo ""
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}💡 Tipp: Es kann 1-2 Minuten dauern, bis ChirpStack vollständig gestartet ist.${NC}"
    echo -e "${YELLOW}    Falls die Web-UI nicht sofort erreichbar ist, warten Sie kurz und versuchen es erneut.${NC}"
}

# --- Hauptlogik ---
print_header
check_root
detect_storages
check_bridge
prompt_for_config
download_template
create_lxc
wait_for_network
install_chirpstack
verify_installation
finish_message

echo ""
echo -e "${GREEN}✅ Setup abgeschlossen!${NC}"
exit 0
