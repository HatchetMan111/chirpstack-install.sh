#!/usr/bin/env bash
#
# Script Name: ChirpStack V4 Installer for Proxmox VE (LXC - Fixed)
# Author: Enhanced Version
# Date: 2025-12-16
# Description: Creates a Debian 12 (Bookworm) LXC container with ChirpStack V4

set -e

# --- Variablen und Konfiguration ---
LXC_TEMPLATE_URL="http://download.proxmox.com/images/system/debian-12-standard_12.7-1_amd64.tar.zst"
LXC_TEMPLATE_NAME="debian-12-standard_12.7-1_amd64.tar.zst"
DB_PASS="chirpstack123" 
ROOT_PASS="proxmox"
LXC_CID_DEFAULT=900
LXC_HOSTNAME_DEFAULT="chirpstack"
LXC_RAM_DEFAULT=2048
LXC_CPU_DEFAULT=2
LXC_DISK_DEFAULT=10
LXC_VETH_BRIDGE="vmbr0"
NET_CONFIG="ip=dhcp"    

# --- Farben ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

function print_header() {
    clear
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
    
    LXC_TEMPLATE_STORAGE=$(pvesm status -content vztmpl | awk 'NR>1 {print $1}' | head -n1)
    if [[ -z "$LXC_TEMPLATE_STORAGE" ]]; then
        echo -e "${RED}❌ Kein Storage mit 'vztmpl' Content-Type gefunden!${NC}"
        exit 1
    fi
    
    LXC_STORAGE=$(pvesm status -content rootdir | awk 'NR>1 {print $1}' | head -n1)
    if [[ -z "$LXC_STORAGE" ]]; then
        echo -e "${RED}❌ Kein Storage mit 'rootdir' Content-Type gefunden!${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✓ Template Storage: $LXC_TEMPLATE_STORAGE${NC}"
    echo -e "${GREEN}✓ Container Storage: $LXC_STORAGE${NC}"
    echo ""
}

function prompt_for_config() {
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}                  Container Konfiguration${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    read -rp "Container ID (Standard: $LXC_CID_DEFAULT): " LXC_CID
    LXC_CID=${LXC_CID:-$LXC_CID_DEFAULT}
    
    if pct status $LXC_CID &> /dev/null; then
        echo -e "${RED}❌ Container ID $LXC_CID ist bereits in Verwendung.${NC}"
        exit 1
    fi

    read -rp "Hostname (Standard: $LXC_HOSTNAME_DEFAULT): " LXC_HOSTNAME
    LXC_HOSTNAME=${LXC_HOSTNAME:-$LXC_HOSTNAME_DEFAULT}

    read -rp "Root-Passwort für Container (Standard: $ROOT_PASS): " CUSTOM_ROOT_PASS
    ROOT_PASS=${CUSTOM_ROOT_PASS:-$ROOT_PASS}
    
    read -rp "Datenbank-Passwort (Standard: $DB_PASS): " CUSTOM_DB_PASS
    DB_PASS=${CUSTOM_DB_PASS:-$DB_PASS}
    
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}                    Zusammenfassung${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  Container ID:        ${BLUE}$LXC_CID${NC}"
    echo -e "  Hostname:            ${BLUE}$LXC_HOSTNAME${NC}"
    echo -e "  Root-Passwort:       ${BLUE}$ROOT_PASS${NC}"
    echo -e "  DB-Passwort:         ${BLUE}$DB_PASS${NC}"
    echo -e "  CPU/RAM/Disk:        ${BLUE}${LXC_CPU} Cores / ${LXC_RAM}MB / ${LXC_DISK}GB${NC}"
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
    echo -e "${GREEN}📥 Prüfe LXC-Template...${NC}"
    
    if pvesm list $LXC_TEMPLATE_STORAGE | grep -q "$LXC_TEMPLATE_NAME"; then
        echo -e "${GREEN}✓ Template vorhanden${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}⏳ Lade Template herunter...${NC}"
    cd /var/lib/vz/template/cache 2>/dev/null || mkdir -p /var/lib/vz/template/cache && cd /var/lib/vz/template/cache
    wget -q --show-progress "$LXC_TEMPLATE_URL" -O "$LXC_TEMPLATE_NAME"
    echo -e "${GREEN}✓ Download abgeschlossen${NC}"
}

function create_lxc() {
    echo ""
    echo -e "${GREEN}🔧 Erstelle Container...${NC}"

    pct create $LXC_CID "$LXC_TEMPLATE_STORAGE:vztmpl/$LXC_TEMPLATE_NAME" \
        --hostname "$LXC_HOSTNAME" \
        --cores "$LXC_CPU" \
        --memory "$LXC_RAM" \
        --rootfs "$LXC_STORAGE:$LXC_DISK" \
        --swap 512 \
        --unprivileged 1 \
        --net0 "name=eth0,bridge=$LXC_VETH_BRIDGE,$NET_CONFIG,type=veth" \
        --features "nesting=1" \
        --ostype debian \
        --onboot 1 \
        --password "$ROOT_PASS"

    echo -e "${GREEN}✓ Container erstellt${NC}"
    pct start $LXC_CID
    echo -e "${YELLOW}⏳ Warte 30s auf Systemstart...${NC}"
    sleep 30
}

function install_chirpstack() {
    echo ""
    echo -e "${GREEN}📦 Installiere ChirpStack...${NC}"
    echo ""

    echo -e "${YELLOW}[1/10] System-Update...${NC}"
    pct exec $LXC_CID -- bash -c "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y"
    
    echo -e "${YELLOW}[2/10] Basis-Pakete...${NC}"
    pct exec $LXC_CID -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y wget curl gnupg2 apt-transport-https ca-certificates net-tools sudo"
    
    echo -e "${YELLOW}[3/10] PostgreSQL + Redis...${NC}"
    pct exec $LXC_CID -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql postgresql-contrib redis-server"
    
    echo -e "${YELLOW}[4/10] ChirpStack Repository...${NC}"
    pct exec $LXC_CID -- bash -c "mkdir -p /etc/apt/keyrings/"
    pct exec $LXC_CID -- bash -c "wget -qO - https://artifacts.chirpstack.io/packages/chirpstack.key | gpg --dearmor > /etc/apt/keyrings/chirpstack.gpg"
    pct exec $LXC_CID -- bash -c "echo 'deb [signed-by=/etc/apt/keyrings/chirpstack.gpg] https://artifacts.chirpstack.io/packages/4.x/deb stable main' > /etc/apt/sources.list.d/chirpstack.list"
    
    echo -e "${YELLOW}[5/10] Paketliste aktualisieren...${NC}"
    pct exec $LXC_CID -- bash -c "apt-get update"
    
    echo -e "${YELLOW}[6/10] ChirpStack + Mosquitto...${NC}"
    pct exec $LXC_CID -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y chirpstack mosquitto mosquitto-clients"
    
    echo -e "${YELLOW}[7/10] Warte auf PostgreSQL Start...${NC}"
    sleep 10
    
    echo -e "${YELLOW}[8/10] Erstelle Datenbank...${NC}"
    # Erstelle User und Datenbank
    pct exec $LXC_CID -- bash -c "sudo -u postgres psql <<EOF
DROP DATABASE IF EXISTS chirpstack;
DROP ROLE IF EXISTS chirpstack;
CREATE ROLE chirpstack WITH LOGIN PASSWORD '$DB_PASS';
CREATE DATABASE chirpstack WITH OWNER chirpstack;
\c chirpstack
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS hstore;
GRANT ALL PRIVILEGES ON DATABASE chirpstack TO chirpstack;
GRANT ALL ON SCHEMA public TO chirpstack;
EOF"
    
    echo -e "${YELLOW}[9/10] Konfiguriere ChirpStack...${NC}"
    # Backup der Original-Config
    pct exec $LXC_CID -- bash -c "cp /etc/chirpstack/chirpstack.toml /etc/chirpstack/chirpstack.toml.bak"
    
    # Setze die Datenbank-Verbindung korrekt
    pct exec $LXC_CID -- bash -c "cat > /etc/chirpstack/chirpstack.toml <<'EOFCONFIG'
[logging]
level=\"info\"

[postgresql]
dsn=\"postgres://chirpstack:$DB_PASS@localhost/chirpstack?sslmode=disable\"
max_open_connections=10

[redis]
servers=[\"redis://localhost/\"]

[network]
net_id=\"000000\"

[api]
bind=\"0.0.0.0:8080\"
secret=\"you-must-replace-this\"

[gateway]
[gateway.backend]
[gateway.backend.mqtt]
event_topic_template=\"gateway/{{ gateway_id }}/event/{{ event }}\"
command_topic_template=\"gateway/{{ gateway_id }}/command/{{ command }}\"

[gateway.backend.mqtt.auth]
type=\"generic\"

[integration]
enabled=[\"mqtt\"]

[integration.mqtt]
event_topic_template=\"application/{{ application_id }}/device/{{ dev_eui }}/event/{{ event }}\"
command_topic_template=\"application/{{ application_id }}/device/{{ dev_eui }}/command/{{ command }}\"
EOFCONFIG"
    
    # Ersetze das Passwort in der Config
    pct exec $LXC_CID -- bash -c "sed -i 's/\$DB_PASS/$DB_PASS/g' /etc/chirpstack/chirpstack.toml"
    
    echo -e "${YELLOW}[10/10] Starte Dienste...${NC}"
    pct exec $LXC_CID -- bash -c "systemctl enable postgresql redis-server mosquitto chirpstack"
    pct exec $LXC_CID -- bash -c "systemctl restart postgresql redis-server mosquitto"
    sleep 5
    pct exec $LXC_CID -- bash -c "systemctl restart chirpstack"
    
    echo -e "${YELLOW}⏳ Warte 10s auf ChirpStack Start...${NC}"
    sleep 10
    
    echo -e "${GREEN}✓ Installation abgeschlossen${NC}"
}

function verify_installation() {
    echo ""
    echo -e "${YELLOW}🔍 Überprüfe Dienste...${NC}"
    echo ""
    
    # Status aller Dienste
    for service in postgresql redis-server mosquitto chirpstack; do
        if pct exec $LXC_CID -- systemctl is-active --quiet $service; then
            echo -e "${GREEN}✓ $service läuft${NC}"
        else
            echo -e "${RED}✗ $service läuft NICHT${NC}"
            if [ "$service" = "chirpstack" ]; then
                echo -e "${YELLOW}Fehlerlog:${NC}"
                pct exec $LXC_CID -- journalctl -u chirpstack -n 30 --no-pager | tail -20
            fi
        fi
    done
    
    echo ""
    echo -e "${YELLOW}Port-Check:${NC}"
    pct exec $LXC_CID -- bash -c "netstat -tlnp | grep -E ':(8080|5432|6379|1883)'" || echo -e "${YELLOW}Ports noch nicht offen${NC}"
}

function finish_message() {
    ACTUAL_IP=$(pct exec $LXC_CID -- hostname -I | awk '{print $1}')
    
    if [[ -z "$ACTUAL_IP" ]]; then
        ACTUAL_IP="KEINE IP - Bitte prüfen!"
    fi
    
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                  🎉 Installation Abgeschlossen!            ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  📦 Container ID:          ${BLUE}$LXC_CID${NC}"
    echo -e "  🏷️  Hostname:              ${BLUE}$LXC_HOSTNAME${NC}"
    echo -e "  🌐 IP-Adresse:            ${BLUE}$ACTUAL_IP${NC}"
    echo -e "  🔗 Web-UI:                ${BLUE}http://$ACTUAL_IP:8080${NC}"
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}                      Zugangsdaten${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${GREEN}SSH/Console:${NC}  root / ${BLUE}$ROOT_PASS${NC}"
    echo -e "  ${GREEN}Web-UI:${NC}       admin / ${BLUE}admin${NC}"
    echo -e "  ${GREEN}Datenbank:${NC}    chirpstack / ${BLUE}$DB_PASS${NC}"
    echo ""
    echo -e "${RED}⚠️  WICHTIG: Passwörter in Produktion ändern!${NC}"
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}                    Nützliche Befehle${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${GREEN}Container betreten:${NC}"
    echo -e "    ${BLUE}pct enter $LXC_CID${NC}"
    echo ""
    echo -e "  ${GREEN}Status prüfen (im Container):${NC}"
    echo -e "    ${BLUE}systemctl status chirpstack${NC}"
    echo -e "    ${BLUE}journalctl -u chirpstack -f${NC}"
    echo ""
    echo -e "  ${GREEN}ChirpStack neustarten:${NC}"
    echo -e "    ${BLUE}systemctl restart chirpstack${NC}"
    echo ""
    echo -e "  ${GREEN}Alle Logs anzeigen:${NC}"
    echo -e "    ${BLUE}journalctl -u chirpstack -n 100${NC}"
    echo ""
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
}

# --- Hauptprogramm ---
print_header
check_root
detect_storages
prompt_for_config
download_template
create_lxc
install_chirpstack
verify_installation
finish_message

echo ""
echo -e "${GREEN}✅ Setup abgeschlossen! Teste jetzt: http://\$IP:8080${NC}"
exit 0
