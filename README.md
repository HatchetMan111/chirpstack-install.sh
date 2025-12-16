# 📡 Proxmox ChirpStack V4 LXC Helper

Dieses Skript automatisiert die Bereitstellung eines **ChirpStack V4 Network Servers** in einem optimierten **privilegierten LXC-Container** auf Proxmox VE.

ChirpStack V4 ist ein Open-Source LoRaWAN Network Server, der ideal für IoT-Anwendungen ist. Dieses Skript installiert und konfiguriert die notwendigen Abhängigkeiten (PostgreSQL, Redis, Mosquitto) und den ChirpStack-Dienst selbst. 

## ✨ Funktionen

* Automatisches Herunterladen des Debian 12 (Bookworm) Templates.
* Interaktive Abfrage von Container ID, Hostname, Ressourcen und Netzwerk-Einstellungen (DHCP oder statische IP).
* Installation und Start von PostgreSQL, Redis, Mosquitto und dem ChirpStack Network Server V4.
* Erstellt die erforderliche PostgreSQL-Datenbank und den Benutzer.
* Setzt die Basis-Datenbankverbindung in der `chirpstack.toml`.

## ⚙️ Voraussetzungen

1.  Ein installierter und konfigurierter Proxmox VE Server (Version 7.x oder 8.x).
2.  Ausreichend freier Speicherplatz auf dem gewählten Storage (mindestens 8 GB).
3.  Das Skript muss als `root` auf dem Proxmox Host ausgeführt werden.

## 🚀 Installation (Auf dem Proxmox Host)

Führen Sie die folgenden Schritte direkt über SSH oder die Proxmox Shell aus.

### 1. Skript herunterladen

Verwenden Sie diesen Befehl, um das Skript direkt von Ihrem GitHub-Repository herunterzuladen:

```bash
wget -qO chirpstack-install.sh [https://raw.githubusercontent.com/HatchetMan111/chirpstack-install.sh/main/chirpstack-install.sh](https://raw.githubusercontent.com/HatchetMan111/chirpstack-install.sh/main/chirpstack-install.sh)
