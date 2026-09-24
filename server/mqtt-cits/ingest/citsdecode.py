"""GeoNetworking/BTP extraction and CAM/DENM decoding – Python port of website/its.js + camdenm.js.

decode(frame) -> dict with the columns stored in the `packets` table (missing values are None).
"""
import math
from datetime import datetime, timedelta, timezone

SNAP_GN = bytes([0xAA, 0xAA, 0x03, 0x00, 0x00, 0x00, 0x89, 0x47])
MESSAGE_TYPES = {1: "DENM", 2: "CAM", 3: "POI", 4: "SPATEM", 5: "MAPEM", 6: "IVIM", 9: "SREM", 10: "SSEM",
                 13: "RTCMEM", 14: "CPM", 15: "IMZM", 16: "VAM"}
PORT_TYPES = {2001: "CAM", 2002: "DENM", 2003: "MAPEM", 2004: "SPATEM", 2006: "IVIM", 2007: "SREM",
              2008: "SSEM", 2009: "CPM", 2018: "VAM"}
# TimestampIts: TAI ms since 2004-01-01; 5 leap seconds since then
ITS_EPOCH = datetime(2004, 1, 1, tzinfo=timezone.utc) - timedelta(seconds=5)


class Bits:
    def __init__(self, data, byte_offset=0):
        self.b, self.p = data, byte_offset * 8

    def n(self, width):
        if self.p + width > len(self.b) * 8:
            raise ValueError("PER payload ended early")
        v = 0
        for _ in range(width):
            v = (v << 1) | ((self.b[self.p >> 3] >> (7 - (self.p & 7))) & 1)
            self.p += 1
        return v

    def bit(self):
        return self.n(1) == 1

    def int(self, lo, hi):
        rng = hi - lo + 1
        return lo + self.n(0 if rng <= 1 else math.ceil(math.log2(rng)))

    def length(self):
        if not self.bit():
            return self.n(7)
        if not self.bit():
            return self.n(14)
        raise ValueError("fragmented length")

    def skip_open_type(self):
        self.p += self.length() * 8

    def normally_small(self):
        return self.length() if self.bit() else self.n(6)

    def skip_extensions(self):
        count = self.length() if self.bit() else self.n(6) + 1
        present = sum(1 for _ in range(count) if self.bit())
        for _ in range(present):
            self.skip_open_type()

    def choice(self, root_count, extensible):
        if extensible and self.bit():
            self.normally_small()
            self.skip_open_type()
            return None
        return self.n(0 if root_count <= 1 else math.ceil(math.log2(root_count)))


def _parse_common(f, common, secured):
    if len(f) < common + 8 or ((f[common] >> 4) & 0x0F) != 2:
        return None
    header_type = f[common + 1] & 0xF0
    if header_type == 0x40:
        ext_len, pos_off = 44, 4
    elif header_type == 0x50:
        ext_len, pos_off = 28, 0
    else:
        return None
    payload_len = (f[common + 4] << 8) | f[common + 5]
    if payload_len < 10:
        return None
    ext = common + 8
    btp = ext + ext_len
    if btp + payload_len > len(f):
        return None
    its = btp + 4
    version, msg_id = f[its], f[its + 1]
    if not 1 <= version <= 3 or msg_id == 0:
        return None
    lat = lon = None
    lpv = ext + pos_off
    if len(f) >= lpv + 20:
        la = int.from_bytes(f[lpv + 12:lpv + 16], "big", signed=True) / 1e7
        lo = int.from_bytes(f[lpv + 16:lpv + 20], "big", signed=True) / 1e7
        if abs(la) <= 90 and abs(lo) <= 180 and not (la == 0 and lo == 0):
            lat, lon = la, lo
    port = (f[btp] << 8) | f[btp + 1]
    return {
        "btp_port": port, "protocol_version": version, "message_id": msg_id, "secured": secured,
        "msg_type": MESSAGE_TYPES.get(msg_id) or PORT_TYPES.get(port) or f"msg {msg_id}",
        "station_id": int.from_bytes(f[its + 2:its + 6], "big"),
        "lat": lat, "lon": lon, "pdu": bytes(f[its:btp + payload_len]),
    }


def extract_its(frame):
    snap = frame.find(SNAP_GN)
    if snap < 0:
        return None
    basic = snap + len(SNAP_GN)
    if len(frame) < basic + 4:
        return None
    nxt = frame[basic] & 0x0F
    if nxt == 1:
        return _parse_common(frame, basic + 4, False)
    if nxt == 2:
        start = basic + 4
        found = None
        for off in range(start, min(len(frame) - 8 + 1, start + 512)):
            p = _parse_common(frame, off, True)
            if p:
                if found:
                    return None
                found = p
        return found
    return None


def _reference_position(r):
    lat = r.int(-900000000, 900000001)
    lon = r.int(-1800000000, 1800000001)
    r.n(12); r.n(12); r.n(12); r.n(20); r.n(4)
    if lat == 900000001 or lon == 1800000001:
        return None, None
    return lat / 1e7, lon / 1e7


def decode_cam(pdu):
    r = Bits(pdu, 6)
    r.n(16)
    r.bit(); has_low = r.bit(); has_special = r.bit()
    basic_ext = r.bit()
    cam = {"station_type": r.n(8), "speed_kmh": None, "heading": None, "vehicle_role": None,
           "light_bar": None, "siren": None}
    cam["lat"], cam["lon"] = _reference_position(r)
    if basic_ext:
        r.skip_extensions()
    if r.choice(2, True) != 0:
        return cam
    opt = [r.bit() for _ in range(7)]
    heading = r.int(0, 3601); r.n(7)
    if heading < 3601:
        cam["heading"] = heading / 10
    speed = r.int(0, 16383); r.n(7)
    if speed < 16383:
        cam["speed_kmh"] = speed / 100 * 3.6
    r.n(2); r.n(10); r.n(3); r.n(6); r.n(9); r.n(7); r.n(11); r.n(3)
    if r.bit():
        r.normally_small()
    else:
        r.n(2)
    r.n(16); r.n(4)
    if opt[0]: r.n(7)
    if opt[1]: r.n(4)
    if opt[2]: r.n(10); r.n(7)
    if opt[3]: r.n(9); r.n(7)
    if opt[4]: r.n(9); r.n(7)
    if opt[5]: r.n(3)
    if opt[6]:
        ext, has_id = r.bit(), r.bit()
        r.n(31); r.n(32)
        if has_id: r.n(27)
        if ext: r.skip_extensions()
    if has_low:
        if r.choice(1, True) is None:
            return cam
        cam["vehicle_role"] = r.n(4)
        r.n(8)
        for _ in range(r.int(0, 40)):
            t = r.bit(); r.n(18); r.n(18); r.n(15)
            if t: r.n(16)
    if has_special:
        kind = r.choice(7, True)
        light = None
        if kind == 3:
            sub = r.bit(); r.bit()
            if sub: r.n(8)
            light = r.n(2)
        elif kind == 4:
            light = r.n(2)
        elif kind == 5:
            r.n(2); light = r.n(2)
        elif kind == 6:
            r.n(3); light = r.n(2)
        if light is not None:
            cam["light_bar"], cam["siren"] = bool(light & 2), bool(light & 1)
    return cam


def decode_denm(pdu):
    r = Bits(pdu, 6)
    has_situation = r.bit(); r.bit(); r.bit()
    mgmt_ext = r.bit()
    has_term, has_dist, has_dir, has_validity, has_interval = (r.bit() for _ in range(5))
    origin, seq = r.n(32), r.n(16)
    detection, reference = r.n(42), r.n(42)
    if has_term: r.n(1)
    lat, lon = _reference_position(r)
    if has_dist: r.n(3)
    if has_dir: r.n(2)
    validity = r.int(0, 86400) if has_validity else 600
    if has_interval: r.n(14)
    station_type = r.n(8)
    if mgmt_ext:
        r.skip_extensions()
    denm = {
        "denm_origin": origin, "denm_sequence": seq, "denm_terminated": has_term,
        "denm_detection": ITS_EPOCH + timedelta(milliseconds=detection),
        "denm_reference": ITS_EPOCH + timedelta(milliseconds=reference),
        "denm_validity": validity, "station_type": station_type, "event_lat": lat, "event_lon": lon,
        "denm_cause": None, "denm_subcause": None,
    }
    if has_situation:
        r.n(3); r.n(3); r.bit()
        denm["denm_cause"], denm["denm_subcause"] = r.n(8), r.n(8)
    return denm


def decode(frame: bytes) -> dict:
    """All columns for one received frame. Never raises; decode errors land in `decode_error`."""
    row = {"msg_type": None, "message_id": None, "btp_port": None, "station_id": None, "secured": None,
           "lat": None, "lon": None, "station_type": None, "speed_kmh": None, "heading": None,
           "vehicle_role": None, "light_bar": None, "siren": None, "denm_origin": None, "denm_sequence": None,
           "denm_cause": None, "denm_subcause": None, "denm_detection": None, "denm_reference": None,
           "denm_validity": None, "denm_terminated": None, "event_lat": None, "event_lon": None,
           "decode_error": None}
    its = extract_its(frame)
    if not its:
        row["decode_error"] = "no GeoNetworking/BTP-B"
        return row
    pdu = its.pop("pdu")
    its.pop("protocol_version")
    row.update(its)
    try:
        if its["message_id"] == 2:
            row.update(decode_cam(pdu))
        elif its["message_id"] == 1:
            row.update(decode_denm(pdu))
    except ValueError as e:
        row["decode_error"] = str(e)
    return row
