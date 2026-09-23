"""Archives every its/<node>/packet message as a daily PCAP per node.

/archive/<node>/<YYYY-MM-DD>.pcap, LINKTYPE_IEEE802_11 (105), timestamped on arrival (UTC).
Open directly in Wireshark.
"""
import os
import re
import struct
import time
from datetime import datetime, timezone

import paho.mqtt.client as mqtt

ROOT = "/archive"
SAFE = re.compile(r"[^A-Za-z0-9._-]")
handles = {}


def pcap_for(node: str, day: str):
    key = (node, day)
    if key not in handles:
        for old in [k for k in handles if k[0] == node]:
            handles.pop(old).close()
        folder = os.path.join(ROOT, node)
        os.makedirs(folder, exist_ok=True)
        path = os.path.join(folder, f"{day}.pcap")
        new = not os.path.exists(path) or os.path.getsize(path) == 0
        f = open(path, "ab", buffering=0)
        if new:
            f.write(struct.pack("<IHHiIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, 105))
        handles[key] = f
    return handles[key]


def on_connect(client, userdata, flags, reason, props):
    print("connected", reason, flush=True)
    client.subscribe("its/+/packet", qos=0)


def on_message(client, userdata, msg):
    node = SAFE.sub("_", msg.topic.split("/")[1])[:64] or "unknown"
    now = time.time()
    day = datetime.fromtimestamp(now, timezone.utc).strftime("%Y-%m-%d")
    sec, usec = int(now), int((now % 1) * 1_000_000)
    data = msg.payload
    pcap_for(node, day).write(struct.pack("<IIII", sec, usec, len(data), len(data)) + data)


client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="cits-archiver")
client.username_pw_set(os.environ["ADMIN_USER"], os.environ["ADMIN_PASS"])
client.on_connect = on_connect
client.on_message = on_message
client.reconnect_delay_set(1, 60)
client.connect(os.environ.get("MQTT_HOST", "mosquitto"), int(os.environ.get("MQTT_PORT", "1883")))
client.loop_forever()
