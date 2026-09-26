import SwiftUI

struct CamTransmitView: View {
    @Environment(CamSender.self) private var sender
    @Environment(BridgeModel.self) private var model

    var body: some View {
        @Bindable var sender = sender
        Form {
            Section {
                Label {
                    Text("Sendet deine iPhone-Position als unsignierte CAM auf 5,9 GHz. Der ESP32-C5 ist dafür nicht zertifiziert; Serienfahrzeuge verwerfen unsignierte CAMs in aller Regel, einfache Empfänger und Karten zeigen dich aber an. Nur zu Test- und Forschungszwecken verwenden.")
                        .font(.footnote)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }

            Section("Einstellungen") {
                Picker("Typ", selection: $sender.stationType) {
                    ForEach(CamSender.selectableTypes, id: \.self) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
                Picker("Kennung", selection: $sender.identityMode) {
                    ForEach(CamSender.IdentityMode.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Station-ID") { Text(verbatim: String(sender.identity.stationId)).monospacedDigit() }
                LabeledContent("MAC") { Text(sender.identity.macString).font(.body.monospaced()) }
                if sender.identityMode == .fixed {
                    Button("Neue feste Kennung erzeugen") { sender.renewFixedIdentity() }.disabled(sender.active)
                }
                Stepper("Intervall: \(sender.intervalMs) ms", value: $sender.intervalMs, in: 100...1000, step: 100)
                    .disabled(sender.active)
            }
            .disabled(sender.active)

            Section {
                if sender.active {
                    LabeledContent("Status", value: sender.waitingForGps ? "warte auf GPS…" : "sendet")
                    LabeledContent("Gesendet / bestätigt / Fehler", value: "\(sender.sent) / \(sender.confirmed) / \(sender.failed)")
                    if let e = sender.lastError { LabeledContent("Letzter Fehler", value: e) }
                    Button(role: .destructive) { sender.stop() } label: {
                        Label("Senden stoppen", systemImage: "stop.circle.fill").frame(maxWidth: .infinity)
                    }
                } else {
                    if !model.linkState.isStreaming {
                        Text("Empfänger nicht verbunden.").foregroundStyle(.secondary)
                    }
                    SlideToConfirm(title: "Zum Senden schieben") { sender.start() }
                        .disabled(!model.linkState.isStreaming)
                        .opacity(model.linkState.isStreaming ? 1 : 0.4)
                    if let e = sender.lastError { Text(e).font(.caption).foregroundStyle(.red) }
                }
            } header: {
                Text("Senden")
            } footer: {
                Text("Gesendet wird nur, solange die App geöffnet ist. „Wechselnd“ erzeugt bei jedem Start und alle 10 Minuten eine neue Station-ID und MAC, wie es echte Fahrzeuge zum Schutz der Privatsphäre tun.")
            }
        }
        .navigationTitle("CAM senden")
    }
}

/// Slide-to-confirm control for actions that must not happen by accident.
struct SlideToConfirm: View {
    let title: String
    let action: () -> Void
    @State private var offset: CGFloat = 0
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        GeometryReader { geo in
            let knob: CGFloat = 52
            let maxOffset = geo.size.width - knob - 8
            ZStack(alignment: .leading) {
                Capsule().fill(Color.red.opacity(0.15))
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.red)
                    .frame(maxWidth: .infinity).opacity(1 - Double(offset / max(maxOffset, 1)))
                Circle().fill(Color.red)
                    .overlay(Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.white))
                    .frame(width: knob, height: knob)
                    .padding(4)
                    .offset(x: offset)
                    .gesture(DragGesture()
                        .onChanged { v in if enabled { offset = min(max(0, v.translation.width), maxOffset) } }
                        .onEnded { _ in
                            if offset > maxOffset * 0.9 { action() }
                            withAnimation(.spring) { offset = 0 }
                        })
            }
        }
        .frame(height: 60)
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}
