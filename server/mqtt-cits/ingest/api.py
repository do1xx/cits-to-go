"""Kleine Lese-API für cits.dirksreich.de (Statistik, Empfänger, Warnungen, Abdeckung).

Nur lesend, Antworten 60 s gecacht. Läuft hinter nginx unter /api/.
"""
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import psycopg
from psycopg.rows import dict_row

CACHE = {}
TTL = 60
CAUSES = {1: "Verkehrsstörung", 2: "Unfall", 3: "Baustelle", 6: "Glätte", 9: "Gefährlicher Straßenzustand",
          10: "Hindernis auf der Fahrbahn", 11: "Tier auf der Fahrbahn", 12: "Personen auf der Fahrbahn",
          14: "Falschfahrer", 15: "Rettungs- und Bergungsarbeiten", 17: "Extremwetter", 18: "Sichtbehinderung",
          19: "Niederschlag", 26: "Langsames Fahrzeug", 27: "Stauende", 91: "Panne", 92: "Unfallfahrzeug",
          93: "Notfall im Fahrzeug", 94: "Liegengebliebenes Fahrzeug", 95: "Einsatzfahrzeug nähert sich",
          96: "Gefährliche Kurve", 97: "Kollisionsgefahr", 98: "Rotlichtverstoß", 99: "Gefahrensituation"}


def query(sql, params=()):
    with psycopg.connect(os.environ["DATABASE_URL"], row_factory=dict_row) as conn:
        return conn.execute(sql, params).fetchall()


def stats():
    totals = query("""
        SELECT count(*) AS packets_24h, count(DISTINCT station_id) AS stations_24h,
               count(DISTINCT node) AS receivers_24h
        FROM packets WHERE time > now() - interval '24 hours'""")[0]
    totals["warnings_7d"] = query("""
        SELECT count(DISTINCT (denm_origin, denm_sequence)) AS n FROM packets
        WHERE msg_type = 'DENM' AND time > now() - interval '7 days'""")[0]["n"]
    hourly = query("""
        SELECT time_bucket('1 hour', time) AS hour, count(*) AS packets
        FROM packets WHERE time > now() - interval '7 days' GROUP BY 1 ORDER BY 1""")
    types = query("""
        SELECT coalesce(msg_type, 'kein C-ITS') AS type,
               count(*) FILTER (WHERE time > now() - interval '24 hours') AS last_24h,
               count(*) AS last_7d
        FROM packets WHERE time > now() - interval '7 days' GROUP BY 1 ORDER BY 3 DESC""")
    receivers = query("""
        SELECT r.node, r.name, r.status, r.info->>'hwv' AS hardware,
               max(p.time) AS last_packet,
               count(p.*) FILTER (WHERE p.time > now() - interval '24 hours') AS packets_24h
        FROM receivers r LEFT JOIN packets p ON p.node = r.node AND p.time > now() - interval '7 days'
        GROUP BY r.node, r.name, r.status, r.info ORDER BY last_packet DESC NULLS LAST""")
    warnings = query("""
        SELECT DISTINCT ON (denm_origin, denm_sequence) denm_origin, denm_sequence, denm_cause, denm_subcause,
               denm_detection, denm_validity, event_lat, event_lon, node
        FROM packets WHERE msg_type = 'DENM' AND time > now() - interval '7 days'
        ORDER BY denm_origin, denm_sequence, time""")
    warnings.sort(key=lambda w: w["denm_detection"] or 0, reverse=True)
    for w in warnings:
        w["cause"] = CAUSES.get(w["denm_cause"], f"Warnung (Code {w['denm_cause']})")
        w["event_lat"] = round(w["event_lat"], 4) if w["event_lat"] is not None else None
        w["event_lon"] = round(w["event_lon"], 4) if w["event_lon"] is not None else None
    return {"totals": totals, "hourly": hourly, "types": types, "receivers": receivers, "warnings": warnings[:50]}


def coverage(days):
    days = max(1, min(days, 90))
    rows = query("""
        SELECT round(lat::numeric, 3)::float AS lat, round(lon::numeric, 3)::float AS lon,
               count(*) AS n, count(DISTINCT station_id) AS stations
        FROM packets WHERE lat IS NOT NULL AND time > now() - make_interval(days => %s)
        GROUP BY 1, 2""", (days,))
    return {"days": days, "cells": rows}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlparse(self.path)
        q = parse_qs(url.query)
        key = self.path
        hit = CACHE.get(key)
        try:
            if hit and time.time() - hit[0] < TTL:
                body = hit[1]
            else:
                if url.path == "/stats":
                    data = stats()
                elif url.path == "/coverage":
                    data = coverage(int(q.get("days", ["7"])[0]))
                else:
                    self.send_error(404)
                    return
                body = json.dumps(data, default=lambda v: v.isoformat() if hasattr(v, "isoformat") else str(v), ensure_ascii=False).encode()
                CACHE[key] = (time.time(), body)
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "max-age=60")
            self.end_headers()
            self.wfile.write(body)
        except (psycopg.Error, ValueError) as e:
            self.send_error(500, str(e)[:200])

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    print("API auf :8095", flush=True)
    ThreadingHTTPServer(("0.0.0.0", 8095), Handler).serve_forever()
