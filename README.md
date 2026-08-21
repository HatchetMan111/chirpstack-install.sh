# 📡 Proxmox ChirpStack V4 LXC Helper

Dieses Skript automatisiert die Bereitstellung eines **ChirpStack V4 Network Servers** in einem **unprivilegierten Debian 12 LXC-Container** auf Proxmox VE – nach dem Vorbild der bekannten Community-Scripts.

ChirpStack V4 ist ein Open-Source LoRaWAN Network Server für IoT-Anwendungen. Das Skript installiert und konfiguriert alle Abhängigkeiten (PostgreSQL, Redis, Mosquitto) sowie ChirpStack selbst – **vollautomatisch von der Erstellung bis zur lauffähigen Weboberfläche**.

## ✨ Funktionen

* Automatisches Herunterladen des aktuellsten Debian 12 Templates (korrekt über `pveam`, funktioniert mit **jedem** Storage)
* Interaktive Auswahl von Template-/Container-Storage und Netzwerk-Bridge
* Abfrage von Container ID, Hostname, Ressourcen und Netzwerk (**DHCP oder statische IP** mit Validierung)
* Abfrage von Root- und PostgreSQL-Passwort mit **Standard-Defaults** (`proxmox` / `chirpstack_db_secure`) – beim Start frei änderbar
* Automatische Generierung des ChirpStack API Secrets
* Installation & Konfiguration von PostgreSQL (inkl. `pg_trgm` + `hstore` Extensions), Redis und Mosquitto
* Optionale MQTT-Freigabe (Port 1883) für LoRaWAN-Gateways im Netzwerk
* **Reboot-persistent:** Container startet automatisch (`onboot=1`), alle Dienste sind aktiviert – **keine manuellen Schritte nach einem Neustart nötig**
* Health-Check: Das Skript meldet Erfolg erst, wenn der ChirpStack-Dienst wirklich läuft
* Ausgabe der **erreichbaren Server-IP** am Ende + Speicherung aller Zugangsdaten in `/root/chirpstack-info-<CTID>.txt`
* Automatisches Aufräumen: Bei fehlgeschlagener Installation wird der unvollständige Container optional entfernt
* Sichere Eingabeverarbeitung (Validierung aller Eingaben, kein `eval`)

## ⚙️ Voraussetzungen

1. Ein installierter und konfigurierter Proxmox VE Server (Version 7.x oder 8.x).
2. Ausreichend freier Speicherplatz auf dem gewählten Storage (mind. 8 GB empfohlen).
3. Internetzugang auf dem Proxmox Host.
4. Das Skript muss als `root` auf dem Proxmox Host ausgeführt werden.

## 🚀 Installation (Auf dem Proxmox Host)

Führen Sie die folgenden Schritte direkt über SSH oder die Proxmox Shell aus.

### 1. Skript herunterladen und starten

```bash
wget -qO chirpstack-install.sh https://raw.githubusercontent.com/HatchetMan111/chirpstack-install.sh/main/chirpstack-install.sh && chmod +x chirpstack-install.sh && ./chirpstack-install.sh
```

### 2. Den Anweisungen folgen

Das Skript fragt Storage, Bridge, Container ID, Hostname, Ressourcen, Netzwerkeinstellungen und Passwörter ab (leere Eingabe = Standardwert).

## 🎉 Nach der Installation

Am Ende zeigt das Skript:

| Information | Beschreibung |
|---|---|
| **Web Interface** | `http://<IP>:8080` – die IP wird automatisch ermittelt und ausgegeben |
| **Admin Login** | `admin` / `admin` → ⚠️ **bitte sofort ändern!** |
| **Zugangsdaten** | Werken zusätzlich in `/root/chirpstack-info-<CTID>.txt` (Rechte `600`) gespeichert |

## 🔄 Verhalten beim Neustart

Es sind **keine Zusatzschritte erforderlich**:

* Der Container ist mit `onboot=1` konfiguriert und startet automatisch mit dem Proxmox-Host.
* PostgreSQL, Redis, Mosquitto und ChirpStack sind als systemd-Dienste aktiviert.
* **Hinweis:** Bei DHCP kann sich die Container-IP nach einem Neustar ändern. Für eine feste Adresse entweder eine DHCP-Reservierung einrichten oder bei der Installation eine statische IP wählen.

## 🔒 Sicherheitshinweise

* ⚠️ **Standard-Passwörter ändern:** Die Defaults (`proxmox` / `chirpstack_db_secure`) sind öffentlich in diesem Repository sichtbar! Geben Sie bei der Installation eigene Passwörter ein oder ändern Sie die Passwörter spätestens nach der Installation (`pct enter <CTID>` → `passwd`).
* **Standard-Login ändern:** Melden Sie sich umgehend unter `http://<IP>:8080` an und ändern Sie das Passwort des `admin`-Benutzers.
* **MQTT ohne Authentifizierung:** Wenn Sie MQTT für Gateways freigeben, ist der Broker im LAN ohne Passwort erreichbar (üblich für LoRaWAN-Gateways, aber nur in vertrauenswürdigen Netzen verwenden!). Alternativ können Sie MQTT auf localhost beschränken und Gateways per UDP anbinden.
* Alle generierten Zugangsdaten werden nur lokal in `/root/chirpstack-info-<CTID>.txt` abgelegt (nur Root lesbar).

## 🛠️ Fehlerbehebung

```bash
# Status der Dienste im Container prüfen
pct exec <CTID> -- systemctl status chirpstack

# Logs ansehen
pct exec <CTID> -- journalctl -u chirpstack -f

# In den Container wechseln
pct enter <CTID>
```

Bei einer fehlgeschlagenen Installation bietet das Skript an, den unvollständigen Container automatisch zu entfernen.

## 📄 Lizenz

Siehe [LICENSE](LICENSE).
