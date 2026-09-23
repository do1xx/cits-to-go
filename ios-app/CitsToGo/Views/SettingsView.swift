import SwiftUI

struct SettingsView: View {
    @Environment(BridgeModel.self) private var model
    @State private var confirmForget = false

    var body: some View {
        @Bindable var model = model
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
                    Text("Erstkopplung: Empfänger per USB an Mac/PC, `python3 ios-app/tools/arm_enrollment.py` ausführen, dann innerhalb von 30 s „Verbinden“ tippen und „Koppeln“ bestätigen. Nach einem Neu-Flashen mit Löschen muss das Gerät zusätzlich unter iOS-Einstellungen › Bluetooth ignoriert werden.")
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
                    Text("OpenTrafficMap / eigener Broker")
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
