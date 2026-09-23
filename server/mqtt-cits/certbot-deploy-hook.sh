#!/bin/sh
# /etc/letsencrypt/renewal-hooks/deploy/mqtt-cits.sh
case " $RENEWED_DOMAINS " in *" mqtt.dirksreich.de "*) ;; *) exit 0 ;; esac
install -d -m 750 -o 1883 -g 1883 /opt/mqtt-cits/certs
install -m 640 -o 1883 -g 1883 "$RENEWED_LINEAGE/fullchain.pem" /opt/mqtt-cits/certs/fullchain.pem
install -m 600 -o 1883 -g 1883 "$RENEWED_LINEAGE/privkey.pem" /opt/mqtt-cits/certs/privkey.pem
docker restart mqtt-cits >/dev/null
