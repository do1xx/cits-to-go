#!/bin/sh
# Spielt die Webseite auf den Hetzner (/var/www/cits). Aufruf: ./website/deploy.sh
set -e
cd "$(dirname "$0")"
COPYFILE_DISABLE=1 tar --no-xattrs -czf - --exclude deploy.sh . | ssh hetzner 'mkdir -p /var/www/cits && cd /var/www/cits && tar xzf - --no-same-owner && chmod -R a+rX /var/www/cits'
echo "Deployed to /var/www/cits"
