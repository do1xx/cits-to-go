# CITS-to-go (iPhone-Version)

Ein kleiner Empfänger für **C-ITS**: Funknachrichten, die Autos, Ampeln und Baustellen im
5,9-GHz-Band aussenden. Ein ESP32-C5 empfängt sie und schickt sie per Bluetooth an ein
iPhone. Die App zeigt sie an und leitet sie auf Wunsch an einen Server weiter.

**Webseite:** <https://cits.dirksreich.de> · **Firmware flashen:** <https://cits.dirksreich.de/flash.html>

## Was ist in diesem Repo?

| Ordner | Inhalt |
|---|---|
| `ios-app/` | iPhone-App (SwiftUI): Live-Nachrichten, Kreuzungen mit Ampelphasen, 3D-Karte, Warnungen, Live-Aktivität, Weiterleitung per MQTT |
| `firmware/` | Firmware für den Seeed Studio XIAO ESP32-C5 (Rust + ESP-IDF) |
| `website/` | Die Webseite: Flash-Seite, Live-Karte, Statistik, Empfangskarte |
| `server/` | MQTT-Server, Archiv, Datenbank (TimescaleDB) und Lese-API, alles per Docker |
| `pi-bridge/` | Fester Empfänger: ESP per USB an einem Raspberry Pi, der die Daten hochlädt |
| `android-app/` | Die ursprüngliche Android-App von sascha8a |

## Loslegen

1. ESP32-C5 per USB anschließen und auf der [Flash-Seite](https://cits.dirksreich.de/flash.html) die Firmware installieren.
2. iPhone-App über TestFlight installieren (Zugang per Mail an mail@dirkreich.com).
3. In der App auf **Verbinden** tippen und den Code **666666** eingeben.

## Was gegenüber dem Original geändert wurde

- **iPhone-App** komplett neu.
- **Firmware:** Kopplung per Code (ab Werk 666666, in der App änderbar) statt USB-Freigabe,
  Status-LED (Blitz alle 2 s = wartet, Dauerlicht = App verbunden).
- **Server und Webseite** für die gemeinsame Live-Karte.

## Firmware-Updates

Jede Änderung unter `firmware/` wird von GitHub Actions automatisch gebaut, als
[Release](https://github.com/do1xx/cits-to-go/releases) abgelegt und auf der Flash-Seite
veröffentlicht. Die Versionsnummer steht in `firmware/VERSION`.

## Herkunft und Lizenz

Fork von [sascha8a/cits-to-go](https://codeberg.org/sascha8a/cits-to-go) (Firmware, Android-App),
das auf der Arbeit von [OpenTrafficMap](https://opentrafficmap.org) aufbaut. Die Original-README
steht in [README.upstream.md](README.upstream.md). Lizenz: GPL-3.0, siehe [LICENSE](LICENSE).

Experimentell, nicht für sicherheitsrelevante Zwecke.
