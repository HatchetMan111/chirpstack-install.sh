#!/usr/bin/env bash
#
# Script Name: ChirpStack V4 Installer for Proxmox VE (LXC - Optimized)
# Description: Creates a Debian 12 (Bookworm) LXC container with ChirpStack V4
# Fixes: Input validation, API Secret generation, Network wait states

set -e

# --- Standardwerte ---
LXC_TEMPLATE_URL="http://download.proxmox.com/images/system/debian-12-standard_12.7-1_amd64.tar.zst"
LXC_TEMPLATE_NAME="debian-12-standard_12.7-1_amd64.tar.zst"
DB_PASS="chirpstack_db_secure"
ROOT_PASS="proxmox"
LXC_CID_DEFAULT=900
LXC_HOSTNAME_DEFAULT="chirpstack-v4"
LXC_RAM_DEFAULT=2048
LXC_CPU_DEFAULT=2
LXC_DISK_DEFAULT=10
LXC_VETH_BRIDGE="vmbr0"
LXC_NET_IP="dhcp"

# --- Farben & Styles ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# --- Hilfsfunktionen ---
function msg_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
function msg_ok() { echo -e "${GREEN}✅ $1${NC}"; }
function msg_warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
function msg_err() { echo -e "${RED}❌ $1${NC}"; exit 1; }

function header() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║     ChirpStack V4 Installer für Proxmox VE (LXC)          ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# --- Checks ---
if [[ $EUID -ne 0 ]]; then msg_err "Dieses Skript muss als Root ausgeführt werden."; fi

# --- Storage Erkennung ---
msg_info "Erkenne Storages..."
# Sucht nach Storage für Templates (vztmpl)
LXC_TEMPLATE_STORAGE=$(pvesm status -content vztmpl | awk 'NR>1 {print $1}' | head -n1)
# Sucht nach Storage für Container RootFS (rootdir)
LXC_STORAGE=$(pvesm status -content rootdir | awk 'NR>1 {print $1}' | head -n1)

[[ -z "$LXC_TEMPLATE_STORAGE" ]] && msg_err "Kein Storage für Templates (vztmpl) gefunden!"
[[ -z "$LXC_STORAGE" ]] && msg_err "Kein Storage für Container (rootdir) gefunden!"

msg_ok "Template Storage: $LXC_TEMPLATE_STORAGE"
msg_ok "Container Storage: $LXC_STORAGE"
echo ""

# --- Konfiguration ---
echo -e "${BOLD}--- Konfiguration ---${NC}"

# Funktion für sichere Eingabe
function read_input() {
    local prompt="$1"
    local default="$2"
    local var_ref="$3"
    local input
    read -rp "$prompt [$default]: " input
    # Entferne Leerzeichen
    input=$(echo "$input" | xargs)
    if [[ -z "$input" ]]; then
        eval "$var_ref='$default'"
    else
        eval "$var_ref='$input'"
    fi
}

# Eingaben abfragen
read_input "Container ID" "$LXC_CID_DEFAULT" LXC_CID
if pct status "$LXC_CID" &>/dev/null; then msg_err "ID $LXC_CID existiert bereits!"; fi

read_input "Hostname" "$LXC_HOSTNAME_DEFAULT" LXC_HOSTNAME
read_input "CPU Kerne" "$LXC_CPU_DEFAULT" LXC_CPU
read_input "RAM (MB)" "$LXC_RAM_DEFAULT" LXC_RAM
read_input "Festplatte (GB)" "$LXC_DISK_DEFAULT" LXC_DISK
read_input "Passwort (Container Root)" "$ROOT_PASS" RUN_ROOT_PASS
read_input "Passwort (Postgres DB)" "$DB_PASS" RUN_DB_PASS

# API Secret generieren
API_SECRET=$(openssl rand -base64 32)

echo ""
echo -e "${YELLOW}Zusammenfassung:${NC}"
echo "ID: $LXC_CID | Host: $LXC_HOSTNAME | CPU: $LXC_CPU | RAM: ${LXC_RAM}MB"
echo ""
read -rp "Installation starten? (j/N): " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[JjYy]$ ]]; then msg_err "Abgebrochen."; fi

# --- Template ---
TEMPLATE_PATH="/var/lib/vz/template/cache/$LXC_TEMPLATE_NAME"
if ! pvesm list "$LXC_TEMPLATE_STORAGE" | grep -q "$LXC_TEMPLATE_NAME"; then
    msg_info "Lade Template herunter..."
    mkdir -p /var/lib/vz/template/cache
    wget -q --show-progress "$LXC_TEMPLATE_URL" -O "$TEMPLATE_PATH" || msg_err "Download fehlgeschlagen"
else
    msg_ok "Template bereits vorhanden."
fi

# --- Container Erstellung ---
msg_info "Erstelle Container $LXC_CID..."
pct create "$LXC_CID" "$LXC_TEMPLATE_STORAGE:vztmpl/$LXC_TEMPLATE_NAME" \
    --hostname "$LXC_HOSTNAME" \
    --cores "$LXC_CPU" \
    --memory "$LXC_RAM" \
    --swap 512 \
    --rootfs "$LXC_STORAGE:$LXC_DISK" \
    --net0 "name=eth0,bridge=$LXC_VETH_BRIDGE,ip=$LXC_NET_IP,type=veth" \
    --features "nesting=1" \
    --ostype debian \
    --unprivileged 1 \
    --password "$RUN_ROOT_PASS" \
    --onboot 1 || msg_err "Fehler beim Erstellen des Containers"

msg_ok "Container erstellt."
pct start "$LXC_CID"
msg_info "Warte auf Netzwerk..."

# Warten bis Netzwerk im Container da ist (wichtig!)
for i in {1..30}; do
    if pct exec "$LXC_CID" -- ping -c 1 8.8.8.8 &>/dev/null; then
        break
    fi
    echo -n "."
    sleep 1
done
echo ""

# --- Installation ---

function lxc_exec() {
    pct exec "$LXC_CID" -- bash -c "$1"
}

msg_info "Update System..."
lxc_exec "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y"
lxc_exec "DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget gnupg2 sudo ca-certificates"

msg_info "Installiere Abhängigkeiten (Redis, Postgres, Mosquitto)..."
lxc_exec "DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql postgresql-contrib redis-server mosquitto mosquitto-clients"

msg_info "Füge ChirpStack Repo hinzu..."
lxc_exec "mkdir -p /etc/apt/keyrings"
lxc_exec "wget -qO - https://artifacts.chirpstack.io/packages/chirpstack.key | gpg --dearmor > /etc/apt/keyrings/chirpstack.gpg"
lxc_exec "echo 'deb [signed-by=/etc/apt/keyrings/chirpstack.gpg] https://artifacts.chirpstack.io/packages/4.x/deb stable main' > /etc/apt/sources.list.d/chirpstack.list"
lxc_exec "apt-get update"

msg_info "Installiere ChirpStack..."
lxc_exec "DEBIAN_FRONTEND=noninteractive apt-get install -y chirpstack"

msg_info "Konfiguriere Datenbank..."
# Datenbank Setup mit Variablen
lxc_exec "sudo -u postgres psql -c \"CREATE ROLE chirpstack WITH LOGIN PASSWORD '$RUN_DB_PASS';\"" || true
lxc_exec "sudo -u postgres psql -c \"CREATE DATABASE chirpstack WITH OWNER chirpstack;\"" || true
lxc_exec "sudo -u postgres psql -d chirpstack -c \"CREATE EXTENSION IF NOT EXISTS pg_trgm;\""
lxc_exec "sudo -u postgres psql -d chirpstack -c \"CREATE EXTENSION IF NOT EXISTS hstore;\""

msg_info "Schreibe ChirpStack Konfiguration..."
lxc_exec "cp /etc/chirpstack/chirpstack.toml /etc/chirpstack/chirpstack.toml.bak"

# TOML Konfiguration schreiben
cat <<EOF > /tmp/chirpstack.toml
[logging]
  level="info"

[postgresql]
  dsn="postgres://chirpstack:$RUN_DB_PASS@localhost/chirpstack?sslmode=disable"
  max_open_connections=10

[redis]
  servers=["redis://localhost/"]

[network]
  net_id="000000"

[api]
  bind="0.0.0.0:8080"
  secret="$API_SECRET"

[gateway]
  [gateway.backend]
    [gateway.backend.mqtt]
      event_topic_template="gateway/{{ gateway_id }}/event/{{ event }}"
      command_topic_template="gateway/{{ gateway_id }}/command/{{ command }}"
      server="tcp://localhost:1883"
      username=""
      password=""
      clean_session=true

[integration]
  enabled=["mqtt"]

  [integration.mqtt]
    event_topic_template="application/{{ application_id }}/device/{{ dev_eui }}/event/{{ event }}"
    command_topic_template="application/{{ application_id }}/device/{{ dev_eui }}/command/{{ command }}"
    server="tcp://localhost:1883"
    username=""
    password=""
    clean_session=true
EOF

# Datei in Container kopieren
pct push "$LXC_CID" /tmp/chirpstack.toml /etc/chirpstack/chirpstack.toml
rm /tmp/chirpstack.toml

msg_info "Starte Dienste neu..."
lxc_exec "systemctl enable postgresql redis-server mosquitto chirpstack"
lxc_exec "systemctl restart postgresql redis-server mosquitto"
sleep 5
lxc_exec "systemctl restart chirpstack"

# Warte kurz auf Start
sleep 5

# --- Abschluss ---
IP=$(pct exec "$LXC_CID" -- hostname -I | awk '{print $1}')
[[ -z "$IP" ]] && IP="<IP-ADRESSE>"

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║             🎉 Installation erfolgreich!                   ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Web Interface:    ${BLUE}http://$IP:8080${NC}"
echo -e "  Admin Login:      ${BLUE}admin / admin${NC}"
echo -e "  Container ID:     $LXC_CID"
echo -e "  DB Passwort:      $RUN_DB_PASS"
echo ""
echo -e "${YELLOW}API Secret generiert:${NC}"
echo -e "$API_SECRET"
echo ""
msg_ok "Fertig."
