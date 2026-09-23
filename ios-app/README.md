# CITS-to-go iOS

iPhone app for the CITS-to-go ESP32-C5 receiver. The iPhone cannot talk USB serial
to the board, so the app uses the firmware's existing **Bluetooth LE GATT service**
(`firmware/main/cits_ble.c`), which carries the same COBS/CTG1 record stream as USB.

Features:

- **Live**: captured frames classified by ITS message type (CAM, DENM, SPATEM, MAPEM,
  IVIM, CPM, …), station ID, RSSI, rate, sequence-gap counter, hex detail view.
- **Kreuzungen**: MAPEM/SPATEM decoder (port of the Android `MapSpatDecoder`) with a
  canvas intersection view: lanes coloured by signal phase, countdown labels,
  signal-group table, your position, pinch zoom.
- **Karte**: stations plotted from their GeoNetworking position vectors.
- **Forwarding**: MQTT 3.1.1 in the OpenTrafficMap topic layout
  (`its/<nodeid>/packet|status|info|stats`), spooling up to 5000 packets offline.
- **PCAP** recording (LINKTYPE_IEEE802_11), shareable and visible in the Files app.
- **Diagnostics**: `Documents/diagnostics.log` with connection events and a
  once-a-minute summary (packets received, MQTT sent/dropped/queued).
- **Demo**: plays a recorded MAPEM with simulated phases (never forwarded or recorded).

## Build

Requires Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
cd ios-app
xcodegen generate
open CitsToGo.xcodeproj
```

Set your own `DEVELOPMENT_TEAM` and `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`.
Unit tests (protocol, COBS/CRC, GeoNetworking extraction, MAPEM/SPATEM decoding against
real secured frames, MQTT encoding, PCAP):

```sh
xcodebuild test -project CitsToGo.xcodeproj -scheme CitsToGo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## First pairing (enrollment)

The firmware only accepts its bonded owner, or one new phone during a 30 s window
armed over USB (USB is the trust anchor). With the receiver plugged into a Mac/PC:

```sh
pip install pyserial
python3 ios-app/tools/arm_enrollment.py        # or pass the port explicitly
```

Then tap **Verbinden** in the app within 30 s and confirm iOS's **Koppeln** dialog.
Afterwards the app reconnects automatically, also in the background and without the Mac.
If the board is re-flashed with a full erase, also *forget* the device in
iOS Settings › Bluetooth before enrolling again.

## Layout

| Path | Contents |
|---|---|
| `CitsToGo/Protocol` | COBS, CRC-32, CTG1 frame decoder/encoder, stream reader |
| `CitsToGo/Transport` | CoreBluetooth client (scan, reconnect, state restoration, encrypted probe) |
| `CitsToGo/ITS` | GeoNetworking/BTP extraction, message types, UPER MAPEM/SPATEM decoder |
| `CitsToGo/Forwarding` | MQTT client (Network.framework), PCAP writer |
| `CitsToGo/App` | pipeline (runs on the BLE queue), observable model, location, diagnostic log |
| `CitsToGo/Views` | SwiftUI screens and the intersection canvas |
| `tools/arm_enrollment.py` | arms BLE enrollment over USB serial |
