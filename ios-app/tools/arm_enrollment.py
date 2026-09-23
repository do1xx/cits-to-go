#!/usr/bin/env python3
"""Arm the CITS-to-go firmware's one-shot BLE enrollment window over USB.

iPhones cannot talk USB-serial to the ESP32-C5, but the firmware only accepts a
new Bluetooth owner after a USB-authorised enrollment request (USB is the trust
anchor, see firmware/main/cits_ble.h). Run this on a Mac/PC with the receiver
plugged in, then open the iOS app within 30 seconds and tap "Verbinden".
iOS will show a "Koppeln" dialog – confirm it.

Usage: python3 arm_enrollment.py [/dev/cu.usbmodemXXXX]
Requires: pip install pyserial
"""
import glob
import struct
import sys
import time
import zlib

import serial  # pyserial

TYPE_BLE_ENROLL_REQUEST = 4
TYPE_BLE_ENROLL_RESULT = 5


def cobs_encode(data: bytes) -> bytes:
    out = bytearray([0])
    code_idx, code = 0, 1
    for b in data:
        if b == 0:
            out[code_idx] = code
            code_idx, code = len(out), 1
            out.append(0)
        else:
            out.append(b)
            code += 1
            if code == 0xFF:
                out[code_idx] = code
                code_idx, code = len(out), 1
                out.append(0)
    out[code_idx] = code
    return bytes(out)


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


def enrollment_request() -> bytes:
    header = bytearray(b"CTG1") + bytes([1, TYPE_BLE_ENROLL_REQUEST]) + struct.pack("<H", 12) + bytes(4)
    header[8] = 1  # replace existing owner, arm exactly one pairing attempt
    body = bytes(header)
    return cobs_encode(body + struct.pack("<I", zlib.crc32(body) & 0xFFFFFFFF)) + b"\x00"


def main() -> int:
    ports = sys.argv[1:] or sorted(glob.glob("/dev/cu.usbmodem*"))
    if not ports:
        print("Kein ESP32-C5 gefunden (/dev/cu.usbmodem*). Port als Argument angeben.")
        return 1
    port = ports[0]
    print(f"Verbinde mit {port} …")
    with serial.Serial(port, 115200, timeout=0.25) as s:
        s.reset_input_buffer()
        s.write(enrollment_request())
        s.flush()
        buf, deadline = bytearray(), time.time() + 3
        while time.time() < deadline:
            for b in s.read(256):
                if b != 0:
                    buf.append(b)
                    continue
                try:
                    rec = cobs_decode(bytes(buf))
                except ValueError:
                    rec = b""
                buf.clear()
                if len(rec) >= 20 and rec[:4] == b"CTG1" and rec[5] == TYPE_BLE_ENROLL_RESULT:
                    status, armed = struct.unpack_from("<I", rec, 8)[0], rec[12]
                    if status == 0 and armed:
                        print("✅ Anlernmodus aktiv für 30 s – jetzt in der iOS-App auf „Verbinden“ tippen und Kopplung bestätigen.")
                        return 0
                    print(f"❌ Firmware hat abgelehnt (status={status}, armed={armed})")
                    return 2
    print("❌ Keine Bestätigung von der Firmware erhalten (läuft die CITS-to-go-Firmware?).")
    return 3


if __name__ == "__main__":
    sys.exit(main())
