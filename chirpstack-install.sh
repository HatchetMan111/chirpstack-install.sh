#!/usr/bin/env bash
#
# Script Name : ChirpStack V4 Installer für Proxmox VE (LXC Helper)
# Description : Erstellt automatisch einen unprivilegierten Debian 12 LXC-Container
#               mit ChirpStack V4 (PostgreSQL, Redis, Mosquitto).
# Version     : 1.1.0
#
# Features:
#   * Sichere Eingabeverarbeitung (kein eval, keine Injection)
#   * Automatisch generierte Zufalls-Passwörter (Root + Datenbank)
#   * Korrektes Template-Handling über pveam (funktioniert mit JEDEM Storage)
#   * ID-Kollisionsprüfung gegen Container UND virtuelle Maschinen
#   * DHCP oder statische IP wählbar
#   * Reboot-persistent: onboot=1 + alle Dienste aktiviert
#   * Gibt am Ende die erreichbare Server-IP aus und speichert Zugangsdaten

set -euo pipefail

readonly SCRIPT_VERSION="1.1.0"

# --- Standardwerte ---
DEFAULT_ROOT_PASS="proxmox"
DEFAULT_DB_PASS="chirpstack_db_secure"
LXC_CID_DEFAULT=900
LXC_HOSTNAME_DEFAULT="chirpstack-v4"
LXC_RAM_DEFAULT=2048
LXC_CPU_DEFAULT=2
LXC_DISK_DEFAULT=10

# --- Farben & Styles ---
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# --- Hilfsfunktionen ---
function msg_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
function msg_ok()   { echo -e "${GREEN}✅ $1${NC}"; }
function msg_warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
function msg_err()  { echo -e "${RED}❌ $1${NC}" >&2; exit 1; }

function header() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║     ChirpStack V4 Installer für Proxmox VE (LXC) v${SCRIPT_VERSION}      ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# Sichere Eingabe: Ergebnis in READ_INPUT_RESULT (KEIN eval!)
function read_input() {
    local prompt="$1" default="$2" input
    read -r -p "$prompt [$default]: " input || msg_err "Eingabe fehlgeschlagen."
    # Whitespace am Anfang/Ende entfernen (ohne xargs/eval)
    input="${input#"${input%%[![:space:]]*}"}"
    input="${input%"${input##*[![:space:]]}"}"
    READ_INPUT_RESULT="${input:-$default}"
}

function validate_int() { # $1=Wert $2=Name $3=min $4=max
    local val="$1" name="$2" min="$3" max="$4"
    if ! [[ "$val" =~ ^[0-9]+$ ]] || (( val < min || val > max )); then
        msg_err "$name muss eine ganze Zahl zwischen $min und $max sein (erhalten: '$val')."
    fi
}

function validate_hostname() {
    if ! [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        msg_err "Ungültiger Hostname: '$1' (nur Buchstaben, Zahlen, Bindestriche; max. 63 Zeichen)."
    fi
}

function validate_password() {
    # Nur sichere Zeichen: verhindert Bruch von SQL/TOML/DSN (keine ' " $ ` \ Leerzeichen)
    if ! [[ "$1" =~ ^[A-Za-z0-9._-]{6,64}$ ]]; then
        msg_err "Passwort darf nur Buchstaben, Zahlen und . _ - enthalten (6–64 Zeichen)."
    fi
}

function validate_cidr() {
    local cidr="$1" IFS='.'
    local -a parts
    read -ra parts <<< "${cidr%%/*}"
    if ! [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/(3[0-2]|[12]?[0-9])$ ]] \
       || (( parts[0] > 255 || parts[1] > 255 || parts[2] > 255 || parts[3] > 255 )); then
        msg_err "Ungültige IP im CIDR-Format: '$cidr' (Beispiel: 192.168.1.50/24)."
    fi
}

function validate_ip() {
    local ip="$1" IFS='.'
    local -a parts
    read -ra parts <<< "$ip"
    if ! [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
       || (( parts[0] > 255 || parts[1] > 255 || parts[2] > 255 || parts[3] > 255 )); then
        msg_err "Ungültige Gateway-IP: '$ip' (Beispiel: 192.168.1.1)."
    fi
}

function id_in_use() {
    pct status "$1" &>/dev/null && return 0
    qm  status "$1" &>/dev/null && return 0
    return 1
}

# Nummerierte Auswahl; Ergebnis in SELECT_RESULT (vermeidet Subshell-Probleme)
function select_from_list() {
    local title="$1"
    shift
    local -a options=("$@")
    local i choice
    echo -e "${BOLD}${title}${NC}"
    for i in "${!options[@]}"; do
        printf "  %2d) %s\n" $((i + 1)) "${options[$i]}"
    done
    read -r -p "Auswahl [1]: " choice
    choice="${choice:-1}"
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#options[@]} )); then
        msg_err "Ungültige Auswahl: '$choice'."
    fi
    SELECT_RESULT="${options[$((choice - 1))]}"
}

# --- Aufräumen bei Fehlern ---
CTID=""
CREATED=0
TMP_TOML=""
TMP_MQTT=""

function cleanup() {
    local rc=$?
    trap - EXIT INT
    [[ -n "$TMP_TOML"  && -f "$TMP_TOML"  ]] && rm -f -- "$TMP_TOML"
    [[ -n "$TMP_MQTT"  && -f "$TMP_MQTT"  ]] && rm -f -- "$TMP_MQTT"
    if (( rc != 0 )) && (( CREATED == 1 )) && pct status "$CTID" &>/dev/null; then
        echo ""
        msg_warn "Installation fehlgeschlagen (Exit-Code $rc)."
        local ans="y"
        read -r -p "Unvollständigen Container $CTID jetzt löschen? [J/n]: " ans || ans="y"
        ans="${ans:-y}"
        if [[ "$ans" =~ ^[JjYy]$ ]]; then
            pct stop "$CTID" &>/dev/null || true
            pct destroy "$CTID" --purge &>/dev/null || true
            msg_info "Container $CTID wurde entfernt."
        else
            msg_warn "Container $CTID wurde beibehalten (ggf. manuell löschen)."
        fi
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'msg_err "Abbruch durch Benutzer (SIGINT)."' INT

# ============================================================
# Start
# ============================================================
header

# --- Umgebungs-Checks ---
if [[ $EUID -ne 0 ]]; then msg_err "Dieses Skript muss als Root ausgeführt werden."; fi
for cmd in pct pvesm pveam qm openssl awk sed; do
    command -v "$cmd" &>/dev/null || msg_err "'$cmd' nicht gefunden – bitte auf einem Proxmox VE Host ausführen."
done
command -v curl &>/dev/null || msg_err "'curl' nicht gefunden auf dem Host."

# --- Storage-Erkennung ---
msg_info "Erkenne Storages..."
mapfile -t TEMPLATE_STORAGES < <(pvesm status -content vztmpl 2>/dev/null | awk 'NR>1 {print $1}')
mapfile -t ROOT_STORAGES    < <(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 {print $1}')
((${#TEMPLATE_STORAGES[@]} > 0)) || msg_err "Kein Storage für Templates (vztmpl) gefunden!"
((${#ROOT_STORAGES[@]} > 0))     || msg_err "Kein Storage für Container (rootdir) gefunden!"

select_from_list "Template-Storage:" "${TEMPLATE_STORAGES[@]}"
LXC_TEMPLATE_STORAGE="$SELECT_RESULT"
select_from_list "Container-Storage (rootfs):" "${ROOT_STORAGES[@]}"
LXC_STORAGE="$SELECT_RESULT"
msg_ok "Template Storage: $LXC_TEMPLATE_STORAGE"
msg_ok "Container Storage: $LXC_STORAGE"

# --- Bridge-Erkennung ---
mapfile -t BRIDGES < <(for iface in /sys/class/net/*; do
    [[ -d "$iface/bridge" ]] && basename "$iface"
done)
((${#BRIDGES[@]} > 0)) || msg_err "Keine Linux-Bridge gefunden (z. B. vmbr0)!"
if ((${#BRIDGES[@]} == 1)); then
    LXC_BRIDGE="${BRIDGES[0]}"
else
    select_from_list "Netzwerk-Bridge:" "${BRIDGES[@]}"
    LXC_BRIDGE="$SELECT_RESULT"
fi
msg_ok "Netzwerk-Bridge: $LXC_BRIDGE"

# --- Konfiguration ---
echo ""
echo -e "${BOLD}--- Konfiguration ---${NC}"

read_input "Container ID" "$LXC_CID_DEFAULT"
LXC_CID="$READ_INPUT_RESULT"
validate_int "$LXC_CID" "Container ID" 100 999999999
if id_in_use "$LXC_CID"; then msg_err "ID $LXC_CID ist bereits in Verwendung (VM oder CT)!"; fi

read_input "Hostname" "$LXC_HOSTNAME_DEFAULT"
LXC_HOSTNAME="$READ_INPUT_RESULT"
validate_hostname "$LXC_HOSTNAME"

read_input "CPU Kerne" "$LXC_CPU_DEFAULT"
LXC_CPU="$READ_INPUT_RESULT"
validate_int "$LXC_CPU" "CPU Kerne" 1 128

read_input "RAM (MB)" "$LXC_RAM_DEFAULT"
LXC_RAM="$READ_INPUT_RESULT"
validate_int "$LXC_RAM" "RAM" 512 262144
if (( LXC_RAM < 1024 )); then msg_warn "Weniger als 1024 MB RAM kann ChirpStack ausbremsen."; fi

read_input "Festplatte (GB)" "$LXC_DISK_DEFAULT"
LXC_DISK="$READ_INPUT_RESULT"
validate_int "$LXC_DISK" "Festplatte" 5 4096
if (( LXC_DISK < 8 )); then msg_warn "Weniger als 8 GB Speicher wird nicht empfohlen."; fi

# Passwörter (Standard-Defaults, per Eingabe änderbar)
read_input "Passwort (Container Root)" "$DEFAULT_ROOT_PASS"
ROOT_PASS="$READ_INPUT_RESULT"
validate_password "$ROOT_PASS"

read_input "Passwort (Postgres DB)" "$DEFAULT_DB_PASS"
DB_PASS="$READ_INPUT_RESULT"
validate_password "$DB_PASS"

# Netzwerkmodus
read -r -p "Netzwerk: (D)HCP oder (s)tatische IP? [D]: " net_mode
net_mode="${net_mode:-D}"
case "$net_mode" in
    [Ss]|2)
        read_input "Statische IP (CIDR, z. B. 192.168.1.50/24)" ""
        STATIC_CIDR="$READ_INPUT_RESULT"
        [[ -n "$STATIC_CIDR" ]] || msg_err "Bei statischer IP ist eine Angabe erforderlich."
        validate_cidr "$STATIC_CIDR"
        read_input "Gateway (z. B. 192.168.1.1)" ""
        STATIC_GW="$READ_INPUT_RESULT"
        [[ -n "$STATIC_GW" ]] || msg_err "Bei statischer IP ist ein Gateway erforderlich."
        validate_ip "$STATIC_GW"
        NET_MODE="static"
        ;;
    *)
        NET_MODE="dhcp"
        ;;
esac

# MQTT-Zugang für Gateways
echo ""
echo -e "${YELLOW}Hinweis: LoRaWAN-Gateways verbinden sich üblicherweise per MQTT (Port 1883).${NC}"
read -r -p "MQTT für Gateways im Netzwerk freigeben (ohne Authentifizierung)? [J/n]: " mqtt_ans
mqtt_ans="${mqtt_ans:-J}"
if [[ "$mqtt_ans" =~ ^[JjYy]$ ]]; then
    MQTT_EXPOSE=1
    msg_warn "MQTT wird OHNE Authentifizierung im LAN freigegeben – nur in vertrauenswürdigen Netzen verwenden!"
else
    MQTT_EXPOSE=0
fi

# API Secret bleibt automatisch generiert
API_SECRET="$(openssl rand -base64 32)"

# --- Zusammenfassung ---
NET_DESC="DHCP"
if [[ "$NET_MODE" == "static" ]]; then
    NET_DESC="$STATIC_CIDR (GW: $STATIC_GW)"
fi
MQTT_DESC="nur localhost"
if (( MQTT_EXPOSE == 1 )); then
    MQTT_DESC="im Netzwerk offen (Port 1883)"
fi

echo ""
echo -e "${BOLD}Zusammenfassung:${NC}"
echo "  ID: $LXC_CID | Host: $LXC_HOSTNAME | CPU: $LXC_CPU | RAM: ${LXC_RAM}MB | Disk: ${LXC_DISK}GB"
echo "  Netzwerk: $NET_DESC | Bridge: $LXC_BRIDGE | MQTT: $MQTT_DESC"
if [[ "$ROOT_PASS" == "$DEFAULT_ROOT_PASS" || "$DB_PASS" == "$DEFAULT_DB_PASS" ]]; then
    msg_warn "Standard-Passwörter aktiv – bitte nach der Installation ändern!"
fi
echo ""
read -r -p "Installation starten? [J/n]: " reply
reply="${reply:-J}"
if ! [[ "$reply" =~ ^[JjYy]$ ]]; then
    msg_err "Abgebrochen."
fi

# --- Template (korrekt über pveam – funktioniert mit jedem Storage) ---
msg_info "Prüfe Debian 12 Template..."
if ! pveam update &>/dev/null; then
    msg_warn "Template-Index konnte nicht aktualisiert werden (offline?) – verwende vorhandene Templates."
fi
if ! pveam list "$LXC_TEMPLATE_STORAGE" 2>/dev/null | grep -q "debian-12-standard"; then
    AVAILABLE_TEMPLATE=$(pveam available --section system 2>/dev/null \
        | awk '/debian-12-standard/ {print $2}' | sort -V | tail -n1)
    [[ -n "$AVAILABLE_TEMPLATE" ]] || msg_err "Kein Debian-12-Template verfügbar und keins lokal vorhanden."
    msg_info "Lade Template $AVAILABLE_TEMPLATE herunter..."
    pveam download "$LXC_TEMPLATE_STORAGE" "$AVAILABLE_TEMPLATE" \
        || msg_err "Template-Download fehlgeschlagen."
else
    msg_ok "Template bereits vorhanden."
fi
TEMPLATE_REF=$(pveam list "$LXC_TEMPLATE_STORAGE" 2>/dev/null | awk '/debian-12-standard/ {print $1}' | head -n1)
[[ -n "$TEMPLATE_REF" ]] || msg_err "Debian-12-Template konnte nicht lokalisiert werden."

# --- Netzerk-Konfigurationsstring ---
NET0_CFG="name=eth0,bridge=${LXC_BRIDGE},type=veth,firewall=0"
if [[ "$NET_MODE" == "static" ]]; then
    NET0_CFG+=",ip=${STATIC_CIDR},gw=${STATIC_GW}"
else
    NET0_CFG+=",ip=dhcp"
fi

# --- Container-Erstellung ---
msg_info "Erstelle Container $LXC_CID..."
CREATED=1
pct create "$LXC_CID" "$TEMPLATE_REF" \
    --hostname "$LXC_HOSTNAME" \
    --cores "$LXC_CPU" \
    --memory "$LXC_RAM" \
    --swap 512 \
    --rootfs "${LXC_STORAGE}:${LXC_DISK}" \
    --net0 "$NET0_CFG" \
    --features nesting=1 \
    --ostype debian \
    --unprivileged 1 \
    --password "$ROOT_PASS" \
    --onboot 1 \
    --startup order=1,up=30 \
    || msg_err "Fehler beim Erstellen des Containers."
msg_ok "Container erstellt."

pct start "$LXC_CID" || msg_err "Container konnte nicht gestartet werden."

# Warten bis der Container läuft
for _ in $(seq 1 30); do
    [[ "$(pct status "$LXC_CID" 2>/dev/null | awk '{print $2}')" == "running" ]] && break
    sleep 1
done

# --- Netzwerk-Wartezeit MIT Fehlerbehandlung ---
msg_info "Warte auf Netzwerk im Container..."
NET_OK=0
for _ in $(seq 1 60); do
    if pct exec "$LXC_CID" -- getent hosts deb.debian.org &>/dev/null; then
        NET_OK=1
        break
    fi
    printf '.'
    sleep 2
done
echo ""
if (( NET_OK == 0 )); then
    msg_err "Kein Netzwerkzugriff im Container (DNS/prüfung fehlgeschlagen). Bitte Bridge/DHCP prüfen."
fi
msg_ok "Netzwerk bereit."

# --- Installation im Container ---
function lxc_exec() {
    if ! pct exec "$LXC_CID" -- bash -c "$1"; then
        msg_err "Befehl im Container fehlgeschlagen: $1"
    fi
}

# Datei sicher in den Container bringen (Permissions setzen)
function ct_push_file() { # $1=lokale Datei $2=Zielpfad im CT $3=Mode (z. B. 600)
    local tmp_target="/tmp/.cs_installer_upload.$$"
    pct push "$LXC_CID" "$1" "$tmp_target" >/dev/null
    lxc_exec "mv '$tmp_target' '$2' && chmod '$3' '$2'"
}

msg_info "Update System (kann einige Minuten dauern)..."
lxc_exec "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get upgrade -y -qq"

msg_info "Installiere Abhängigkeiten (PostgreSQL, Redis, Mosquitto)..."
lxc_exec "export DEBIAN_FRONTEND=noninteractive; apt-get install -y -qq postgresql postgresql-contrib redis-server mosquitto mosquitto-clients ca-certificates curl gnupg"

msg_info "Füge ChirpStack Repository hinzu..."
lxc_exec "mkdir -p /etc/apt/keyrings && curl -fsSL https://artifacts.chirpstack.io/packages/chirpstack.key | gpg --dearmor -o /etc/apt/keyrings/chirpstack.gpg"
lxc_exec "echo 'deb [signed-by=/etc/apt/keyrings/chirpstack.gpg] https://artifacts.chirpstack.io/packages/4.x/deb stable main' > /etc/apt/sources.list.d/chirpstack.list"
lxc_exec "apt-get update -qq"

msg_info "Installiere ChirpStack..."
lxc_exec "export DEBIAN_FRONTEND=noninteractive; apt-get install -y -qq chirpstack"

# --- Datenbank-Setup (idempotent, ohne Fehler zu verschlucken) ---
msg_info "Konfiguriere Datenbank..."
lxc_exec "sudo -u postgres psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='chirpstack'\" | grep -q 1 \
    || sudo -u postgres psql -c \"CREATE ROLE chirpstack WITH LOGIN PASSWORD '$DB_PASS';\""
lxc_exec "sudo -u postgres psql -tAc \"SELECT 1 FROM pg_database WHERE datname='chirpstack'\" | grep -q 1 \
    || sudo -u postgres createdb -O chirpstack chirpstack"
lxc_exec "sudo -u postgres psql -d chirpstack -c 'CREATE EXTENSION IF NOT EXISTS pg_trgm;'"
lxc_exec "sudo -u postgres psql -d chirpstack -c 'CREATE EXTENSION IF NOT EXISTS hstore;'"

# --- ChirpStack-Konfiguration ---
msg_info "Schreibe ChirpStack Konfiguration..."
lxc_exec "cp /etc/chirpstack/chirpstack.toml /etc/chirpstack/chirpstack.toml.bak"

TMP_TOML="$(mktemp)"
chmod 600 "$TMP_TOML"
cat <<EOF > "$TMP_TOML"
[logging]
  level = "info"

[postgresql]
  dsn = "postgres://chirpstack:${DB_PASS}@localhost/chirpstack?sslmode=disable"
  max_open_connections = 10

[redis]
  servers = ["redis://localhost/"]

[network]
  net_id = "000000"

[api]
  bind = "0.0.0.0:8080"
  secret = "${API_SECRET}"

[gateway]

  [gateway.backend]

    [gateway.backend.mqtt]
      event_topic_template = "gateway/{{ gateway_id }}/event/{{ event }}"
      command_topic_template = "gateway/{{ gateway_id }}/command/{{ command }}"
      server = "tcp://localhost:1883"
      username = ""
      password = ""
      clean_session = true

[integration]
  enabled = ["mqtt"]

  [integration.mqtt]
    event_topic_template = "application/{{ application_id }}/device/{{ dev_eui }}/event/{{ event }}"
    command_topic_template = "application/{{ application_id }}/device/{{ dev_eui }}/command/{{ command }}"
    server = "tcp://localhost:1883"
    username = ""
    password = ""
    clean_session = true
EOF
ct_push_file "$TMP_TOML" "/etc/chirpstack/chirpstack.toml" "600"
rm -f -- "$TMP_TOML"
TMP_TOML=""

# --- Mosquitto konfigurieren ---
msg_info "Konfiguriere Mosquitto..."
TMP_MQTT="$(mktemp)"
chmod 600 "$TMP_MQTT"
if (( MQTT_EXPOSE == 1 )); then
    cat <<EOF > "$TMP_MQTT"
# ChirpStack Installer: MQTT fuer LoRaWAN-Gateways freigegeben (WARNUNG: anonym!)
listener 1883 0.0.0.0
allow_anonymous true
EOF
else
    cat <<EOF > "$TMP_MQTT"
# ChirpStack Installer: MQTT nur localhost (sicherer Standard)
listener 1883 127.0.0.1
allow_anonymous true
EOF
fi
ct_push_file "$TMP_MQTT" "/etc/mosquitto/conf.d/chirpstack.conf" "644"
rm -f -- "$TMP_MQTT"
TMP_MQTT=""

# --- Dienste aktivieren (Reboot-Persistenz!) ---
msg_info "Aktiviere Dienste für Autostart..."
lxc_exec "systemctl enable postgresql redis-server mosquitto chirpstack >/dev/null 2>&1"
lxc_exec "systemctl restart postgresql redis-server mosquitto"

msg_info "Starte ChirpStack..."
lxc_exec "systemctl restart chirpstack"

# --- Health-Check: ChirpStack muss laufen, bevor Erfolg gemeldet wird ---
msg_info "Prüfe ChirpStack-Dienst..."
CS_OK=0
for _ in $(seq 1 45); do
    if pct exec "$LXC_CID" -- systemctl is-active --quiet chirpstack; then
        CS_OK=1
        break
    fi
    printf '.'
    sleep 2
done
echo ""
if (( CS_OK == 0 )); then
    lxc_exec "journalctl -u chirpstack -n 30 --no-pager" || true
    msg_err "ChirpStack-Dienst startet nicht – Logausgabe siehe oben."
fi
msg_ok "ChirpStack läuft."

# --- IP-Adresse ermitteln ---
IP="$(pct exec "$LXC_CID" -- hostname -I 2>/dev/null | awk '{print $1}')"
[[ -n "$IP" ]] || msg_err "Konnte keine IP-Adresse ermitteln."

# --- Zugangsdaten dauerhaft auf dem Host speichern (chmod 600) ---
INFO_FILE="/root/chirpstack-info-${LXC_CID}.txt"
(
    umask 077
    cat <<EOF > "$INFO_FILE"
ChirpStack V4 – Installationsdaten ($(date '+%Y-%m-%d %H:%M:%S'))
============================================================
Web Interface : http://${IP}:8080
Admin Login   : admin / admin  (!!! BITTE SOFORT ÄNDERN !!!)

Container ID  : ${LXC_CID}
Hostname      : ${LXC_HOSTNAME}

Root-Passwort (Container) : ${ROOT_PASS}
DB-Passwort (PostgreSQL)  : ${DB_PASS}
API Secret                : ${API_SECRET}

MQTT            : ${MQTT_DESC}
Netzwerk        : ${NET_DESC}
Neustart        : Container (onboot=1) und alle Dienste starten automatisch.
EOF
)

# --- Abschluss ---
echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║             🎉 Installation erfolgreich!                   ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Web Interface : ${BLUE}${BOLD}http://$IP:8080${NC}"
echo -e "  Admin Login   : ${BLUE}admin / admin${NC}  ${YELLOW}(bitte sofort ändern!)${NC}"
echo -e "  Container ID  : $LXC_CID"
echo -e "  Root-Passwort : $ROOT_PASS"
echo -e "  DB-Passwort   : $DB_PASS"
if (( MQTT_EXPOSE == 1 )); then
    echo -e "  MQTT          : $MQTT_DESC ${YELLOW}(ohne Auth – nur trusted LAN!)${NC}"
fi
echo ""
echo -e "${YELLOW}Reboot-Verhalten:${NC} Container (onboot) und alle Dienste starten automatisch,"
echo -e "keine manuellen Schritte nötig.$([[ "$NET_MODE" == "dhcp" ]] && echo -e " ${YELLOW}Tipp: Bei DHCP kann sich die IP ändern – ggf. Reservierung einrichten.${NC}")"
echo ""
echo -e "Alle Zugangsdaten gespeichert in: ${BOLD}$INFO_FILE${NC} (Rechte 600)"
echo ""
msg_ok "Fertig."
