"""Schreibt alle MQTT-Nachrichten unter its/# in die TimescaleDB.

Pakete werden gepuffert und in kleinen Stapeln geschrieben (alle 2 s oder 500 Stück).
Aufruf ohne Argumente: Live-Betrieb. Mit `--backfill DATEI.pcap NODE`: Archiv nachladen.
"""
import json
import os
import struct
import sys
import threading
import time
from datetime import datetime, timezone

import paho.mqtt.client as mqtt
import psycopg

from citsdecode import decode

COLUMNS = ["time", "node", "msg_type", "message_id", "btp_port", "station_id", "secured", "lat", "lon",
           "station_type", "speed_kmh", "heading", "vehicle_role", "light_bar", "siren", "denm_origin",
           "denm_sequence", "denm_cause", "denm_subcause", "denm_detection", "denm_reference",
           "denm_validity", "denm_terminated", "event_lat", "event_lon", "decode_error", "raw"]
INSERT = f"INSERT INTO packets ({', '.join(COLUMNS)}) VALUES ({', '.join(['%s'] * len(COLUMNS))})"


def log(*a):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), *a, flush=True)


def connect_db():
    while True:
        try:
            conn = psycopg.connect(os.environ["DATABASE_URL"], autocommit=True)
            return conn
        except psycopg.OperationalError as e:
            log("Datenbank nicht erreichbar, neuer Versuch in 5 s:", e)
            time.sleep(5)


def ensure_schema(conn):
    with open(os.path.join(os.path.dirname(__file__), "schema.sql")) as f:
        conn.execute(f.read())


def packet_row(ts, node, frame):
    d = decode(frame)
    d["time"], d["node"], d["raw"] = ts, node, frame
    return [d[c] for c in COLUMNS]


def backfill(conn, path, node):
    data = open(path, "rb").read()
    rows, off = [], 24
    while off + 16 <= len(data):
        sec, usec, incl, _ = struct.unpack_from("<IIII", data, off)
        frame = data[off + 16:off + 16 + incl]
        off += 16 + incl
        rows.append(packet_row(datetime.fromtimestamp(sec + usec / 1e6, timezone.utc), node, frame))
    with conn.cursor() as cur:
        cur.executemany(INSERT, rows)
    log(f"{len(rows)} Pakete aus {path} für {node} nachgeladen")


class Ingest:
    def __init__(self):
        self.conn = connect_db()
        ensure_schema(self.conn)
        self.buffer, self.lock = [], threading.Lock()
        self.total = 0

    def on_connect(self, client, userdata, flags, reason, props):
        log("MQTT verbunden:", reason)
        client.subscribe("its/#")

    def on_message(self, client, userdata, msg):
        parts = msg.topic.split("/")
        if len(parts) != 3:
            return
        _, node, leaf = parts
        now = datetime.now(timezone.utc)
        try:
            if leaf == "packet":
                with self.lock:
                    self.buffer.append(packet_row(now, node, bytes(msg.payload)))
            elif leaf in ("status", "info"):
                value = msg.payload.decode("utf-8", "replace")
                col = "status" if leaf == "status" else "info"
                val = value if leaf == "status" else json.dumps(json.loads(value)) if value else None
                self.conn.execute(
                    f"INSERT INTO receivers (node, {col}, updated) VALUES (%s, %s, now()) "
                    f"ON CONFLICT (node) DO UPDATE SET {col} = EXCLUDED.{col}, updated = now()", (node, val))
            elif leaf == "stats":
                self.conn.execute("INSERT INTO receiver_stats (time, node, stats) VALUES (%s, %s, %s)",
                                  (now, node, json.dumps(json.loads(msg.payload))))
        except (ValueError, psycopg.Error) as e:
            log("Nachricht verworfen:", msg.topic, e)

    def flush_loop(self):
        last_report = time.time()
        while True:
            time.sleep(2)
            with self.lock:
                rows, self.buffer = self.buffer, []
            if rows:
                try:
                    with self.conn.cursor() as cur:
                        cur.executemany(INSERT, rows)
                    self.total += len(rows)
                except psycopg.Error as e:
                    log("Schreiben fehlgeschlagen, verbinde neu:", e)
                    self.conn = connect_db()
                    with self.lock:
                        self.buffer = rows + self.buffer
            if time.time() - last_report > 600:
                log(f"{self.total} Pakete gespeichert")
                last_report = time.time()


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "--backfill":
        conn = connect_db()
        ensure_schema(conn)
        backfill(conn, sys.argv[2], sys.argv[3])
        return
    ingest = Ingest()
    threading.Thread(target=ingest.flush_loop, daemon=True).start()
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="cits-ingest")
    client.username_pw_set(os.environ["ADMIN_USER"], os.environ["ADMIN_PASS"])
    client.on_connect = ingest.on_connect
    client.on_message = ingest.on_message
    client.reconnect_delay_set(1, 60)
    client.connect(os.environ.get("MQTT_HOST", "mosquitto"), int(os.environ.get("MQTT_PORT", "1883")))
    log("Ingest gestartet")
    client.loop_forever()


if __name__ == "__main__":
    main()
