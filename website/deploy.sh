#!/bin/sh
# Spielt die Webseite auf den Hetzner (/var/www/cits). Aufruf: ./website/deploy.sh
set -e
cd "$(dirname "$0")"
# Lesezugang für die Live-Seite aus ../.secrets erzeugen (nicht im Git)
. ../.secrets/mqtt.env
printf 'window.CITS_LIVE = { url: "wss://%s/mqtt", username: "%s", password: "%s" };\n' "$MQTT_HOST" "$READ_USER" "$READ_PASS" > live-config.js
COPYFILE_DISABLE=1 tar --no-xattrs -czf - --exclude deploy.sh . | ssh hetzner 'mkdir -p /var/www/cits && cd /var/www/cits && tar xzf - --no-same-owner && chmod -R a+rX /var/www/cits'
echo "Deployed to /var/www/cits"
