import SwiftUI

struct CapturesView: View {
    @Environment(BridgeModel.self) private var model
    @State private var files: [URL] = []

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
            .onAppear(perform: reload)
            .refreshable { model.flushRecording(); reload() }
        }
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
