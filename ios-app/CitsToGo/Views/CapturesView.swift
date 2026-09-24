import SwiftUI
import UniformTypeIdentifiers

struct CapturesView: View {
    @Environment(BridgeModel.self) private var model
    @State private var files: [URL] = []
    @State private var importing = false
    @State private var exported: ExportedFile?
    @State private var exportMessage: String?
    @State private var usage: (bytes: Int64, oldest: Date?) = (0, nil)
    @State private var confirmDeleteRolling = false

    struct ExportedFile: Identifiable { let url: URL; var id: URL { url } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        model.toggleRecording()
                        reload()
                    } label: {
                        Label(model.recordingURL == nil ? "PCAP-Aufnahme starten" : "Aufnahme stoppen",
                              systemImage: model.recordingURL == nil ? "record.circle" : "stop.circle.fill")
                    }
                } footer: {
                    Text("Aufnahmen sind im Format LINKTYPE_IEEE802_11 und lassen sich direkt in Wireshark öffnen. Sie liegen auch in der Dateien-App unter „Auf meinem iPhone › CITS-to-go“.")
                }
                Section {
                    @Bindable var model = model
                    Toggle("Immer mitschneiden", isOn: $model.rollingEnabled)
                    Picker("Aufbewahren", selection: $model.rollingHours) {
                        Text("6 Stunden").tag(6)
                        Text("24 Stunden").tag(24)
                        Text("3 Tage").tag(72)
                    }
                    LabeledContent("Belegt", value: usage.bytes == 0 ? "leer" :
                        "\(ByteCountFormatter.string(fromByteCount: usage.bytes, countStyle: .file))" +
                        (usage.oldest.map { ", seit \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""))
                    Button { export(hours: 1) } label: { Label("Letzte Stunde exportieren", systemImage: "square.and.arrow.up") }
                    Button { export(hours: 24) } label: { Label("Letzte 24 Stunden exportieren", systemImage: "square.and.arrow.up") }
                    Button { export(hours: nil) } label: { Label("Alles exportieren", systemImage: "square.and.arrow.up.on.square") }
                    if let exportMessage { Text(exportMessage).font(.caption).foregroundStyle(.secondary) }
                    Button("Mitschnitt löschen", role: .destructive) { confirmDeleteRolling = true }
                } header: {
                    Text("Automatischer Mitschnitt")
                } footer: {
                    Text("Speichert alle empfangenen Pakete im Hintergrund, auch ohne gestartete Aufnahme – für den Fall, dass man das Aufnehmen vergessen hat. Ältere Daten werden automatisch gelöscht, höchstens 500 MB. Exporte landen zusätzlich unten in der Dateiliste.")
                }

                Section {
                    if let r = model.replay {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Spielt \(r.name) ab").font(.subheadline)
                            ProgressView(value: Double(r.played), total: Double(max(r.total, 1)))
                            Text("\(r.played) von \(r.total) Paketen").font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Wiedergabe stoppen", role: .destructive) { model.stopReplay() }
                    } else {
                        Button { importing = true } label: {
                            Label("Aufnahme aus Dateien abspielen", systemImage: "play.circle")
                        }
                    }
                } footer: {
                    Text("Spielt eine PCAP-Datei im Originaltempo durch Live, Kreuzungen und Karte. Abgespielte Pakete werden nicht weitergeleitet und nicht aufgezeichnet.")
                }
                Section("Dateien") {
                    if files.isEmpty { Text("Keine Aufnahmen").foregroundStyle(.secondary) }
                    ForEach(files, id: \.self) { url in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(url.lastPathComponent).font(.subheadline.monospaced())
                                Text(size(url)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if url == model.recordingURL {
                                Image(systemName: "record.circle").foregroundStyle(.red)
                            } else {
                                Button { model.startReplay(url: url) } label: { Image(systemName: "play.circle") }
                                    .buttonStyle(.borderless).padding(.trailing, 8)
                                    .accessibilityLabel("Abspielen")
                                ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                            }
                        }
                    }
                    .onDelete { idx in
                        for i in idx where files[i] != model.recordingURL { try? FileManager.default.removeItem(at: files[i]) }
                        reload()
                    }
                }
            }
            .navigationTitle("Aufnahmen")
            .sheet(item: $exported) { file in
                NavigationStack {
                    VStack(spacing: 16) {
                        Image(systemName: "doc.zipper").font(.largeTitle).foregroundStyle(.secondary)
                        Text(file.url.lastPathComponent).font(.headline.monospaced())
                        ShareLink(item: file.url) { Label("Teilen oder sichern", systemImage: "square.and.arrow.up") }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { exported = nil } } }
                }
                .presentationDetents([.medium])
            }
            .confirmationDialog("Automatischen Mitschnitt löschen?", isPresented: $confirmDeleteRolling) {
                Button("Löschen", role: .destructive) { model.deleteRolling(); refreshUsage() }
            }
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: [UTType(filenameExtension: "pcap") ?? .data, .data]) { result in
                if case .success(let url) = result { model.startReplay(url: url) }
            }
            .onAppear { reload(); refreshUsage() }
            .refreshable { model.flushRecording(); reload() }
        }
    }

    private func refreshUsage() {
        usage = model.rollingUsage()
    }

    private func export(hours: Int?) {
        let since = hours.map { Date().addingTimeInterval(-Double($0) * 3600) }
        if let url = model.exportRolling(since: since) {
            exportMessage = nil
            exported = ExportedFile(url: url)
            reload()
        } else {
            exportMessage = "Im gewählten Zeitraum wurden keine Pakete empfangen."
        }
        refreshUsage()
    }

    private func reload() {
        let dir = PcapWriter.capturesDirectory
        files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "pcap" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func size(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
