#!/bin/sh
# Validates generated CAM frames with Wireshark (required for every packet generator, see AGENTS.md):
# protocol chain wlan:llc:gnw:btpb:its, messageId 2, no _ws.malformed, and decoder round trip.
set -e
cd "$(dirname "$0")/../../CitsToGo"
OUT=$(mktemp -d)
swiftc -O -o "$OUT/gen" Protocol/Cobs.swift ITS/ItsFrame.swift ITS/IntersectionModels.swift ITS/MapSpatDecoder.swift \
  ITS/UperExtensions.swift ITS/CamDenmDecoder.swift ITS/CamEncoder.swift ../tools/validate-cam-tx/main.swift
"$OUT/gen" "$OUT/cam.pcap"
tshark -r "$OUT/cam.pcap" -T fields -e frame.protocols -e its.messageId -e its.stationType -e btpb.dstport
test "$(tshark -r "$OUT/cam.pcap" -Y '_ws.malformed' | wc -l)" -eq 0 || { echo "MALFORMED"; exit 1; }
test "$(tshark -r "$OUT/cam.pcap" -Y 'its.messageId == 2 && btpb.dstport == 2001' | wc -l)" -eq 5 || { echo "NOT RECOGNISED"; exit 1; }
echo "OK: Wireshark erkennt alle CAMs, keine Fehler"
