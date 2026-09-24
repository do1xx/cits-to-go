# CITS-to-go Pi-Bridge (feste Station)

Ein ESP32-C5 mit CITS-to-go-Firmware hängt per USB an einem Raspberry Pi mit Internet.
Die Bridge leitet jedes empfangene Paket an mehrere MQTT-Server gleichzeitig weiter,
z. B. an den gemeinsamen Server `mqtt.dirksreich.de` und an OpenTrafficMap.
Name und Position der Station werden im `info`-Topic mitgeschickt.

## Installation

```sh
scp -r pi-bridge pi@<pi>:~/cits-bridge
ssh pi@<pi>
cd ~/cits-bridge && sudo ./install.sh cits-bridge.env
```

`cits-bridge.env` nach dem Muster von `cits-bridge.env.example` anlegen (Zugangsdaten
kommen nicht ins Git). Danach läuft die Bridge als Dienst `cits-bridge`, startet beim
Booten und nach Fehlern automatisch neu.

```sh
journalctl -u cits-bridge -f          # Log
sudo systemctl restart cits-bridge    # nach Änderungen an /etc/cits-bridge.env
```

Jede Minute schreibt die Bridge eine Zeile mit den Zählern pro Server ins Log.
