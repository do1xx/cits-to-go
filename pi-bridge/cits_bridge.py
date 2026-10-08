#!/usr/bin/env python3
"""CITS-to-go USB → MQTT bridge for a stationary receiver (e.g. Raspberry Pi).

Reads the CTG1 record stream of the CITS-to-go ESP32-C5 firmware over USB serial and
publishes every captured frame to MQTT in the OpenTrafficMap topic layout:

    its/<node>/packet   raw IEEE 802.11 frame (binary, QoS 1, buffered while offline)
    its/<node>/status   "online" (retained) / last will "offline"
    its/<node>/info     JSON: node, software, hardware, name, lat, lon (retained)
    its/<node>/stats    JSON every 60 s: uptime, packet counters, firmware statistics

Every frame is sent to all configured brokers (CITS_MQTT_URL, CITS_MQTT_URL_2, ...), e.g. the
own community server and OpenTrafficMap. Each target has its own queue and reconnect loop.

Configuration comes from environment variables (see cits-bridge.env.example).
Requires: pyserial, paho-mqtt >= 2.0
"""
import glob
import json
import os
import signal
import ssl
import struct
import sys
import threading
import time
import zlib
from urllib.parse import unquote, urlparse

import paho.mqtt.client as mqtt
import serial

VERSION = "1.0.1"
TYPE_CAPTURE, TYPE_STATISTICS = 1, 6


def log(*args):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), *args, flush=True)


def cobs_decode(data: bytes) -> bytes:
    out, i = bytearray(), 0
    while i < len(data):
        code = data[i]
        i += 1
        if code == 0 or i + code - 1 > len(data):
            raise ValueError("malformed COBS")
        out += data[i:i + code - 1]
        i += code - 1
        if code < 0xFF and i < len(data):
            out.append(0)
    return bytes(out)


def parse_record(rec: bytes):
    """Returns ("capture", frame, rssi, freq) | ("stats", dict) | None."""
    if len(rec) < 12 or rec[:4] != b"CTG1" or rec[4] != 1:
        return None
    if zlib.crc32(rec[:-4]) & 0xFFFFFFFF != struct.unpack_from("<I", rec, len(rec) - 4)[0]:
        return None
    rtype, hlen = rec[5], struct.unpack_from("<H", rec, 6)[0]
    if rtype == TYPE_CAPTURE and hlen == 32:
        caplen = struct.unpack_from("<H", rec, 26)[0]
        if len(rec) != 32 + caplen + 4:
            return None
        freq = struct.unpack_from("<H", rec, 22)[0]
        rssi = struct.unpack_from("<b", rec, 28)[0]
        return ("capture", rec[32:32 + caplen], rssi, freq)
    if rtype == TYPE_STATISTICS and hlen == 112 and len(rec) == 116:
        u32 = lambda o: struct.unpack_from("<I", rec, o)[0]
        return ("stats", {
            "uptimeMs": u32(8), "wifiRxPerSec": u32(16), "capturedPerSec": u32(20),
            "wifiRxTotal": u32(72), "capturedTotal": u32(76), "rxNoBuffer": u32(44),
        })
    return None


class Target:
    """One MQTT broker. Retained status/info are re-published on every (re)connect."""

    def __init__(self, url_text, node, info):
        url = urlparse(url_text)
        tls = url.scheme in ("mqtts", "ssl", "tls")
        self.label = url.hostname
        self.prefix = f"its/{node}/"
        self.info = info
        self.client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=f"cits-bridge-{node}")
        if url.username:
            self.client.username_pw_set(unquote(url.username), unquote(url.password or ""))
        if tls:
            self.client.tls_set(cert_reqs=ssl.CERT_REQUIRED)
        self.client.will_set(self.prefix + "status", "offline", qos=1, retain=True)
        self.client.max_queued_messages_set(int(os.environ.get("CITS_MAX_QUEUE", "20000")))
        self.client.reconnect_delay_set(1, 60)
        self.client.on_connect = self.on_connect
        self.client.on_disconnect = lambda c, u, f, rc, p: log(f"[{self.label}] getrennt: {rc}")
        self.client.connect_async(url.hostname, url.port or (8883 if tls else 1883), keepalive=60)
        self.client.loop_start()
        self.packets = 0
        self.dropped = 0

    def on_connect(self, client, userdata, flags, reason, props):
        log(f"[{self.label}] verbunden: {reason}")
        if reason.is_failure:
            return
        client.publish(self.prefix + "status", "online", qos=1, retain=True)
        client.publish(self.prefix + "info", json.dumps(self.info, ensure_ascii=False), qos=1, retain=True)

    def publish(self, leaf, payload, retain=False):
        # Packets go out with QoS 1: paho then keeps them (up to CITS_MAX_QUEUE) while the
        # broker is unreachable and delivers them after the reconnect. QoS 0 would be lost.
        qos = 1 if leaf == "packet" else 0
        info = self.client.publish(self.prefix + leaf, payload, qos=qos, retain=retain)
        if leaf == "packet":
            if info.rc == mqtt.MQTT_ERR_QUEUE_SIZE:
                self.dropped += 1
            else:
                self.packets += 1

    def stop(self):
        self.client.publish(self.prefix + "status", "offline", qos=1, retain=True)
        time.sleep(0.5)
        self.client.loop_stop()
        self.client.disconnect()


class Bridge:
    def __init__(self):
        env = os.environ
        self.node = env.get("CITS_NODE_ID", "").strip()
        if not self.node:
            sys.exit("CITS_NODE_ID fehlt")
        self.port_pattern = env.get("CITS_SERIAL", "/dev/ttyACM*")
        self.started = time.time()
        self.fw_stats = {}
        self.running = True

        info = {"emac": self.node, "ver": f"cits-bridge {VERSION}", "hwv": "cits-to-go-usb"}
        if env.get("CITS_NAME"):
            info["name"] = env["CITS_NAME"]
        if env.get("CITS_LAT") and env.get("CITS_LON"):
            info["lat"], info["lon"] = float(env["CITS_LAT"]), float(env["CITS_LON"])
        urls = [env[k] for k in sorted(env) if k.startswith("CITS_MQTT_URL") and env[k].strip()]
        if not urls:
            sys.exit("Kein CITS_MQTT_URL konfiguriert")
        self.targets = [Target(u, self.node, info) for u in urls]

    def stats_loop(self):
        while self.running:
            for _ in range(60):
                if not self.running:
                    return
                time.sleep(1)
            for t in self.targets:
                payload = {"rbt": int(time.time() - self.started), "packets": t.packets,
                           "dropped": t.dropped, "fw": self.fw_stats}
                t.publish("stats", json.dumps(payload))
            summary = ", ".join(f"{t.label}: {t.packets} gesendet/{t.dropped} verworfen" for t in self.targets)
            log(f"Firmware {self.fw_stats.get('capturedTotal', '?')} erfasst – {summary}")

    def serial_loop(self):
        while self.running:
            ports = sorted(glob.glob(self.port_pattern))
            if not ports:
                log("Kein ESP gefunden unter", self.port_pattern, "– neuer Versuch in 5 s")
                time.sleep(5)
                continue
            try:
                with serial.Serial(ports[0], 115200, timeout=1) as ser:
                    log("ESP verbunden:", ports[0])
                    buf = bytearray()
                    while self.running:
                        chunk = ser.read(4096)
                        for b in chunk:
                            if b:
                                if len(buf) < 8192:
                                    buf.append(b)
                                continue
                            if buf:
                                try:
                                    rec = parse_record(cobs_decode(bytes(buf)))
                                except ValueError:
                                    rec = None
                                buf.clear()
                                if rec and rec[0] == "capture":
                                    for t in self.targets:
                                        t.publish("packet", rec[1])
                                elif rec and rec[0] == "stats":
                                    self.fw_stats = rec[1]
            except (serial.SerialException, OSError) as e:
                log("USB-Fehler:", e, "– neuer Versuch in 3 s")
                time.sleep(3)

    def stop(self, *_):
        self.running = False
        for t in self.targets:
            t.stop()


def main():
    bridge = Bridge()
    signal.signal(signal.SIGTERM, lambda *a: (bridge.stop(), sys.exit(0)))
    signal.signal(signal.SIGINT, lambda *a: (bridge.stop(), sys.exit(0)))
    threading.Thread(target=bridge.stats_loop, daemon=True).start()
    log(f"CITS-to-go Bridge {VERSION}, Node {bridge.node}")
    bridge.serial_loop()


if __name__ == "__main__":
    main()
