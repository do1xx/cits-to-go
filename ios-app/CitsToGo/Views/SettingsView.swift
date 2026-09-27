import SwiftUI

struct SettingsView: View {
    @Environment(BridgeModel.self) private var model
    @Environment(ScreenAwake.self) private var screen
    @Environment(WarningNotifier.self) private var notifier
    @Environment(LiveActivityManager.self) private var liveActivity
    @State private var confirmForget = false
    @State private var newPin = ""

    var body: some View {
        @Bindable var model = model
        @Bindable var screen = screen
        @Bindable var notifier = notifier
        @Bindable var liveActivity = liveActivity
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Status", value: model.linkState.label)
                    Toggle("Beim Start automatisch verbinden", isOn: $model.autoConnect)
                    if model.hasKnownDevice {
                        Button("Gespeicherten Empfänger vergessen", role: .destructive) { confirmForget = true }
                    }
                } header: {
                    Text("Empfänger (Bluetooth LE)")
                } footer: {
                    Text("Beim ersten Verbinden fragt das iPhone nach dem Kopplungscode: ab Werk 666666. Es kann immer nur ein Handy gleichzeitig verbunden sein. Nach einem Neu-Flashen das Gerät vorher unter iOS-Einstellungen › Bluetooth ignorieren.")
                }

                Section {
                    TextField("Neuer PIN (6 Ziffern)", text: $newPin)
                        .keyboardType(.numberPad)
                        .onChange(of: newPin) { _, v in newPin = String(v.filter(\.isNumber).prefix(6)) }
                    Button("PIN am Empfänger setzen") {
                        if let pin = UInt32(newPin) { model.setBluetoothPin(pin); newPin = "" }
                    }
                    .disabled(newPin.count != 6 || !model.linkState.isStreaming)
                    if let m = model.pinChangeMessage { Text(m).font(.caption).foregroundStyle(.secondary) }
                } header: {
                    Text("Kopplungscode ändern")
                } footer: {
                    Text("Nur möglich, während dieses iPhone mit dem Empfänger verbunden ist. Bereits gekoppelte Handys bleiben gekoppelt, neue brauchen den neuen PIN. Der Code bleibt auch bei Firmware-Updates über die Flash-Seite erhalten.")
                }

                Section {
                    Toggle("Bei Warnungen benachrichtigen", isOn: $notifier.enabled)
                    Picker("Umkreis", selection: $notifier.radiusKm) {
                        Text("1 km").tag(1); Text("5 km").tag(5); Text("20 km").tag(20); Text("Unbegrenzt").tag(0)
                    }
                    .disabled(!notifier.enabled)
                    if notifier.enabled && !notifier.authorized {
                        Text("Mitteilungen sind in den iOS-Einstellungen für CITS-to-go nicht erlaubt.").font(.caption).foregroundStyle(.orange)
                    }
                    Toggle("Live-Aktivität (Sperrbildschirm)", isOn: $liveActivity.enabled)
                } header: {
                    Text("Warnungen")
                } footer: {
                    Text("Meldet jede neue DENM (Stau, Panne, Unfall, Baustelle …) einmal mit Ton, auch bei gesperrtem iPhone. Der Umkreis wird nur beachtet, wenn deine Position bekannt ist. Die Live-Aktivität zeigt auf dem Sperrbildschirm und in der Dynamic Island die nächste Ampel mit Countdown, eine aktuelle Warnung oder den Empfangsstatus.")
                }

                Section {
                    NavigationLink { CamTransmitView() } label: {
                        Label("Eigene Position als CAM senden", systemImage: "dot.radiowaves.left.and.right")
                    }
                } header: {
                    Text("Senden (TX)")
                }

                Section {
                    Picker("Bildschirm anlassen", selection: $screen.mode) {
                        ForEach(KeepAwakeMode.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Nur wenn Empfänger verbunden", isOn: $screen.onlyWhenConnected)
                    LabeledContent("Jetzt", value: screen.active ? "bleibt an" : (screen.mode == .charging && !screen.isCharging ? "aus (lädt nicht)" : "normale Sperre"))
                } header: {
                    Text("Bildschirm")
                } footer: {
                    Text("Hält das Display an, solange die App geöffnet ist – wie bei Navigations-Apps. Empfang, Weiterleitung und Aufnahme laufen auch bei gesperrtem iPhone im Hintergrund weiter.")
                }

                Section {
                    Toggle("An \(BuiltInServers.communityName) senden", isOn: $model.communityEnabled)
                    LabeledContent("Status", value: model.communityEnabled ? model.communityState.label : "Aus")
                    LabeledContent("Gesendet / verworfen", value: "\(model.communityCounters.published) / \(model.communityCounters.dropped)")
                } header: {
                    Text("Gemeinsamer Server")
                } footer: {
                    Text("Sendet die empfangenen Funkpakete an mqtt.dirksreich.de, damit alle Empfänger gesammelt auf cits.dirksreich.de sichtbar sind. Deine eigene Position wird nicht übertragen.")
                }

                Section {
                    Toggle("An eigenen Server senden", isOn: $model.customEnabled)
                    TextField("Adresse, z. B. mqtt.example.org", text: $model.customHost)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    HStack {
                        TextField("Port", text: $model.customPort).keyboardType(.numberPad).frame(maxWidth: 90)
                        Toggle("TLS (verschlüsselt)", isOn: $model.customTLS)
                    }
                    TextField("Benutzer (optional)", text: $model.customUser)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.username)
                    SecureField("Passwort (optional)", text: $model.customPassword).textContentType(.password)
                    TextField("Topic-Präfix, z. B. its/", text: $model.customPrefix)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().font(.body.monospaced())
                    Button("Übernehmen & neu verbinden") { model.applyMqtt() }
                    LabeledContent("Status", value: model.customEnabled ? model.customState.label : "Aus")
                    LabeledContent("Gesendet / verworfen", value: "\(model.customCounters.published) / \(model.customCounters.dropped)")
                } header: {
                    Text("Eigener Server")
                } footer: {
                    Text("Beispiel: Präfix „opentrafficmap/its/“ ergibt \(model.customPrefix.isEmpty ? "its/" : model.customPrefix)\(model.nodeId)/packet. Das Passwort wird im iOS-Schlüsselbund gespeichert.")
                }

                Section {
                    Toggle("An MQTT weiterleiten", isOn: $model.mqttEnabled)
                    TextField("mqtts://user:pass@host:8883", text: $model.mqttUri)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Node-ID", text: $model.nodeId)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().font(.body.monospaced())
                    Button("Übernehmen & neu verbinden") { model.applyMqtt() }
                    LabeledContent("Status", value: model.mqttState.label)
                    LabeledContent("Gesendet / verworfen", value: "\(model.mqttCounters.published) / \(model.mqttCounters.dropped)")
                    Button("OpenTrafficMap-Standard") { model.mqttUri = BridgeModel.defaultMqttUri }
                } header: {
                    Text("OpenTrafficMap")
                } footer: {
                    Text("Topics wie beim OpenTrafficMap-Empfänger: its/\(model.nodeId)/packet (rohe 802.11-Frames), …/status, …/info, …/stats. Offline werden bis zu \(MqttClient.maxSpool) Pakete zwischengespeichert.")
                }

                Section {
                    Toggle("Demo-Kreuzung abspielen", isOn: Binding(get: { model.demoRunning }, set: { _ in model.toggleDemo() }))
                } header: {
                    Text("Demo")
                } footer: {
                    Text("Spielt eine echte aufgezeichnete MAPEM (Bahnhofstr. – 8. Mai Str.) mit simulierten Ampelphasen ab, um die Kreuzungsansicht ohne Ampel in der Nähe auszuprobieren. Wird nicht per MQTT weitergeleitet.")
                }

                Section("Diagnose") {
                    LabeledContent("Protokollfehler", value: "\(model.protocolErrors)")
                    LabeledContent("Verlorene Sequenzen", value: "\(model.missingSequences)")
                    if let e = model.lastError { LabeledContent("Letzter Fehler", value: e) }
                    if let fw = model.firmware {
                        LabeledContent("FW Uptime", value: "\(fw.uptimeMs / 1000) s")
                        LabeledContent("FW WLAN-RX gesamt", value: "\(fw.wifiRxPacketsTotal)")
                        LabeledContent("FW erfasst gesamt", value: "\(fw.capturedPacketsTotal)")
                        LabeledContent("FW BLE MTU / Intervall", value: "\(fw.bleMtu) / \(fw.bleConnectionIntervalMs.map { String(format: "%.2f ms", $0) } ?? "–")")
                        LabeledContent("FW BLE Drops / Notify-Fehler", value: "\(fw.bleOutputDropsTotal) / \(fw.bleNotifyFailuresTotal)")
                        LabeledContent("FW USB verbunden", value: fw.usbConnected ? "ja" : "nein")
                    }
                }

                Section("Verbindungsprotokoll") {
                    if model.eventLog.isEmpty { Text("Noch keine Ereignisse").foregroundStyle(.secondary) }
                    ForEach(model.eventLog.prefix(60)) { e in
                        HStack(alignment: .top) {
                            Text(e.date, format: .dateTime.hour().minute().second())
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(e.message).font(.caption)
                        }
                    }
                }

                Section("Über") {
                    LabeledContent("Version", value: model.appVersion)
                    Link("CITS-to-go (Codeberg)", destination: URL(string: "https://codeberg.org/sascha8a/cits-to-go")!)
                    Link("OpenTrafficMap", destination: URL(string: "https://opentrafficmap.org")!)
                }
            }
            .navigationTitle("Einstellungen")
            .confirmationDialog("Empfänger vergessen?", isPresented: $confirmForget) {
                Button("Vergessen", role: .destructive) { model.forgetDevice() }
            }
        }
    }
}
