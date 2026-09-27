import CoreBluetooth
import Foundation

enum BleLinkState: Equatable, Sendable {
    case bluetoothUnavailable(String)
    case idle
    case scanning
    case connecting(String)
    case securing          // connected, waiting for the encrypted RX probe (pairing dialog may be visible)
    case streaming(mtu: Int)
    case disconnected(String)

    var label: String {
        switch self {
        case .bluetoothUnavailable(let r): "Bluetooth: \(r)"
        case .idle: "Getrennt"
        case .scanning: "Suche Empfänger…"
        case .connecting(let n): "Verbinde mit \(n)…"
        case .securing: "Sichere Verbindung / Kopplung…"
        case .streaming(let mtu): "Verbunden (MTU \(mtu))"
        case .disconnected(let r): "Getrennt: \(r)"
        }
    }

    var isStreaming: Bool { if case .streaming = self { true } else { false } }
}

protocol BleTransportDelegate: AnyObject {
    /// Called on the transport queue.
    func bleTransport(_ t: BleTransport, didReceive bytes: Data)
    /// Called on the transport queue.
    func bleTransport(_ t: BleTransport, didChange state: BleLinkState)
    /// Link dropped before encryption was established: pairing was cancelled or the PIN
    /// was wrong (older firmware: phone not enrolled over USB).
    func bleTransportRejectedUnenrolled(_ t: BleTransport)
    /// The receiver no longer knows this iPhone (reflashed/erased) while iOS still holds the old keys.
    /// iOS will not pair again by itself; the user has to ignore the device in Settings › Bluetooth.
    func bleTransportPairingLost(_ t: BleTransport)
    /// Human-readable connection event for the in-app diagnostic log.
    func bleTransport(_ t: BleTransport, log message: String)
}

/// CoreBluetooth client for the CITS-to-go firmware GATT service (cits_ble.c).
///
/// Service 6e400001-…, RX 6e400002-… (write, encryption required), TX 6e400003-… (notify).
/// The TX characteristic carries the same 0x00-delimited COBS/CTG1 byte stream as USB.
/// Pairing is "Just Works" + bonding; iOS starts it automatically when the encrypted
/// RX characteristic is first written, which is exactly what the Android app's
/// post-enrollment probe (single 0x00 byte) does.
final class BleTransport: NSObject {
    static let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let rxUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    static let txUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    private static let restoreIdentifier = "org.opentrafficmap.citstogo.central"
    private static let knownPeripheralKey = "ble.knownPeripheral"

    let queue = DispatchQueue(label: "cits.ble", qos: .userInitiated)
    weak var delegate: BleTransportDelegate?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var tx: CBCharacteristic?
    private var wantRunning = false
    private var secured = false
    private var pendingWrites: [Data] = []
    private var writeInFlight = false
    private(set) var state: BleLinkState = .idle {
        didSet {
            if state != oldValue {
                log(state.label)
                delegate?.bleTransport(self, didChange: state)
            }
        }
    }

    private func log(_ message: String) { delegate?.bleTransport(self, log: message) }

    /// True (and reported) when `error` means the board dropped our bond.
    private func checkPairingLost(_ error: Error?) -> Bool {
        guard let code = (error as? CBError)?.code, code == .peerRemovedPairingInformation else { return false }
        log("Empfänger kennt dieses iPhone nicht mehr (neu geflasht?) – in iOS unter Bluetooth ignorieren")
        delegate?.bleTransportPairingLost(self)
        return true
    }

    var knownPeripheralId: UUID? {
        get { UserDefaults.standard.string(forKey: Self.knownPeripheralKey).flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: Self.knownPeripheralKey) }
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue, options: [
            CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier,
            CBCentralManagerOptionShowPowerAlertKey: true,
        ])
    }

    // MARK: Public API (thread-safe, hops onto the transport queue)

    func start() { queue.async { self.wantRunning = true; self.connectIfPossible() } }

    func stop() {
        queue.async {
            self.wantRunning = false
            self.central.stopScan()
            if let p = self.peripheral { self.central.cancelPeripheralConnection(p) }
            self.state = .idle
        }
    }

    /// Forget the stored peripheral (the iOS bond itself must be removed in Settings › Bluetooth).
    func forgetDevice() {
        queue.async {
            self.knownPeripheralId = nil
            if let p = self.peripheral { self.central.cancelPeripheralConnection(p) }
            self.peripheral = nil
        }
    }

    /// Writes a complete CTG record (already COBS encoded incl. trailing 0x00).
    func write(_ record: [UInt8]) {
        queue.async {
            guard let p = self.peripheral else { return }
            let chunk = max(20, min(512, p.maximumWriteValueLength(for: .withResponse)))
            var offset = 0
            while offset < record.count {
                let end = min(record.count, offset + chunk)
                self.pendingWrites.append(Data(record[offset..<end]))
                offset = end
            }
            self.pumpWrites()
        }
    }

    // MARK: Internals (transport queue only)

    private func connectIfPossible() {
        guard wantRunning, central.state == .poweredOn else { return }
        if let p = peripheral, p.state == .connected, !secured {
            // Restored by iOS (state restoration) while already connected: didConnect will not
            // fire again, so run the service/notify/security setup ourselves.
            log("Bestehende Verbindung übernommen")
            p.delegate = self
            state = .securing
            p.discoverServices([Self.serviceUUID])
            return
        }
        if let p = peripheral, p.state == .connected || p.state == .connecting { return }

        if let id = knownPeripheralId, let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            log("Bekannten Empfänger \(id.uuidString.prefix(8)) angefordert, suche parallel")
            connect(p)
            // The stored receiver may be switched off, reflashed or replaced by another board:
            // look for any CITS-to-go at the same time and take whichever answers first.
            central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
            return
        }
        if let p = central.retrieveConnectedPeripherals(withServices: [Self.serviceUUID]).first {
            connect(p)
            return
        }
        state = .scanning
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
    }

    private func connect(_ p: CBPeripheral) {
        central.stopScan()
        peripheral = p
        p.delegate = self
        secured = false
        rx = nil; tx = nil
        pendingWrites.removeAll()
        writeInFlight = false
        state = .connecting(p.name ?? "CITS-to-go")
        // A pending connect never times out on iOS, so this also covers "device out of range".
        central.connect(p, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
    }

    private func pumpWrites() {
        guard !writeInFlight, let p = peripheral, let rx, !pendingWrites.isEmpty else { return }
        writeInFlight = true
        p.writeValue(pendingWrites.removeFirst(), for: rx, type: .withResponse)
    }
}

extension BleTransport: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if case .bluetoothUnavailable = state { state = .idle }
            connectIfPossible()
        case .poweredOff: state = .bluetoothUnavailable("ausgeschaltet")
        case .unauthorized: state = .bluetoothUnavailable("keine Berechtigung")
        case .unsupported: state = .bluetoothUnavailable("nicht unterstützt")
        default: state = .bluetoothUnavailable("nicht bereit")
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        wantRunning = true
        log("Von iOS im Hintergrund wiederhergestellt")
        if let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first {
            peripheral = restored
            restored.delegate = self
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if let current = peripheral, current.identifier == p.identifier { return }
        log("Gefunden: \(p.name ?? "?") \(p.identifier.uuidString.prefix(8)) \(RSSI) dBm")
        if let current = peripheral, current.state == .connecting {
            let stale = current
            peripheral = nil
            central.cancelPeripheralConnection(stale)
        }
        connect(p)
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        state = .securing
        p.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        if let current = peripheral, current.identifier != p.identifier { return }
        if checkPairingLost(error) {
            state = .disconnected("Kopplung auf dem Empfänger gelöscht")
            peripheral = nil
            return
        }
        state = .disconnected(error?.localizedDescription ?? "Verbindung fehlgeschlagen")
        peripheral = nil
        queue.asyncAfter(deadline: .now() + 2) { self.connectIfPossible() }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        // A cancelled pending connection to a previously stored board is not our link.
        if let current = peripheral, current.identifier != p.identifier { return }
        if checkPairingLost(error) {
            secured = false
            rx = nil; tx = nil
            peripheral = nil
            state = .disconnected("Kopplung auf dem Empfänger gelöscht")
            return
        }
        let wasSecured = secured
        log("Getrennt (gesichert: \(wasSecured ? "ja" : "nein")): \(error?.localizedDescription ?? "ohne Fehler")")
        secured = false
        rx = nil; tx = nil
        pendingWrites.removeAll()
        writeInFlight = false
        guard wantRunning else { state = .idle; return }

        if !wasSecured && knownPeripheralId != p.identifier {
            // Firmware terminates unknown peers right after connect.
            delegate?.bleTransportRejectedUnenrolled(self)
            state = .disconnected("Kopplung abgebrochen – PIN prüfen")
            peripheral = nil
            queue.asyncAfter(deadline: .now() + 3) { self.connectIfPossible() }
            return
        }
        state = .disconnected(error?.localizedDescription ?? "Verbindung verloren")
        connect(p) // re-arm a pending connection; iOS completes it when the board is back in range
    }
}

extension BleTransport: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let s = p.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            central.cancelPeripheralConnection(p)
            return
        }
        p.discoverCharacteristics([Self.rxUUID, Self.txUUID], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        rx = service.characteristics?.first { $0.uuid == Self.rxUUID }
        tx = service.characteristics?.first { $0.uuid == Self.txUUID }
        guard let rx, let tx else {
            central.cancelPeripheralConnection(p)
            return
        }
        p.setNotifyValue(true, for: tx)
        // Encrypted-write probe: triggers iOS pairing on first use and proves the bond afterwards.
        // An empty CTG record is ignored by the firmware parser.
        writeInFlight = true
        p.writeValue(Data([0]), for: rx, type: .withResponse)
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        writeInFlight = false
        if let error {
            log("Schreibfehler: \(error.localizedDescription)")
            if checkPairingLost(error) { central.cancelPeripheralConnection(p); return }
            if !secured {
                state = .disconnected("Kopplung fehlgeschlagen: \(error.localizedDescription)")
                central.cancelPeripheralConnection(p)
            }
            return
        }
        if !secured {
            secured = true
            knownPeripheralId = p.identifier
            state = .streaming(mtu: p.maximumWriteValueLength(for: .withoutResponse) + 3)
        }
        pumpWrites()
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.uuid == Self.txUUID, let value = characteristic.value else { return }
        delegate?.bleTransport(self, didReceive: value)
    }
}
