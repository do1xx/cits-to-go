import Foundation

/// Always-on ring recording so received data can be exported even if nobody pressed "record".
/// Hourly PCAP files in Application Support/rolling; files older than `retentionHours` or beyond
/// `maxBytes` (oldest first) are deleted. Runs on the pipeline queue.
final class RollingCapture {
    static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("rolling", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var retentionHours: Int
    let maxBytes: Int64 = 500_000_000
    private var writer: PcapWriter?
    private var currentHour: String?
    private let hourFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HH"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    init(retentionHours: Int) { self.retentionHours = retentionHours }

    func write(_ packet: CitsPacket) {
        let hour = hourFormat.string(from: Date())
        if hour != currentHour {
            writer?.close()
            let url = Self.directory.appendingPathComponent("roll-\(hour).pcap")
            // Continue an existing hour file after an app restart by starting a new part.
            let target = FileManager.default.fileExists(atPath: url.path)
                ? Self.directory.appendingPathComponent("roll-\(hour)-\(Int(Date().timeIntervalSince1970)).pcap") : url
            writer = try? PcapWriter(url: target)
            currentHour = hour
            prune()
        }
        writer?.write(packet)
    }

    func flush() { writer?.flush() }

    func close() {
        writer?.close()
        writer = nil
        currentHour = nil
    }

    /// Total size and time span currently held.
    func usage() -> (bytes: Int64, oldest: Date?) {
        let files = listing()
        return (files.reduce(0) { $0 + $1.size }, files.first?.modified)
    }

    func deleteAll() {
        close()
        for f in listing() { try? FileManager.default.removeItem(at: f.url) }
    }

    /// Writes all records received at or after `since` (nil = everything) into one PCAP in the captures folder.
    func export(since: Date?) throws -> (url: URL, packets: Int) {
        flush()
        let cutoff = since.map { UInt32(max(0, $0.timeIntervalSince1970)) } ?? 0
        var out = Data()
        var count = 0
        for f in listing() {
            if let since, f.modified < since { continue }        // file finished before the window
            guard let data = try? Data(contentsOf: f.url), data.count >= 24 else { continue }
            if out.isEmpty { out.append(data.prefix(24)) }
            var off = 24
            while off + 16 <= data.count {
                let sec = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self) }
                let incl = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off + 8, as: UInt32.self) })
                guard off + 16 + incl <= data.count else { break }
                if sec >= cutoff {
                    out.append(data[(data.startIndex + off)..<(data.startIndex + off + 16 + incl)])
                    count += 1
                }
                off += 16 + incl
            }
        }
        guard count > 0 else { throw CocoaError(.fileNoSuchFile) }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        let url = PcapWriter.capturesDirectory.appendingPathComponent("export-\(f.string(from: Date())).pcap")
        try out.write(to: url)
        return (url, count)
    }

    private struct FileInfo { let url: URL; let size: Int64; let modified: Date }

    /// Oldest first.
    private func listing() -> [FileInfo] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: keys)) ?? []
        return urls.filter { $0.pathExtension == "pcap" }.compactMap { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return FileInfo(url: u, size: Int64(v?.fileSize ?? 0), modified: v?.contentModificationDate ?? .distantPast)
        }.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
    }

    private func prune() {
        let limit = Date().addingTimeInterval(-Double(retentionHours) * 3600)
        var files = listing()
        let current = writer?.url
        for f in files where f.modified < limit && f.url != current { try? FileManager.default.removeItem(at: f.url) }
        files = listing()
        var total = files.reduce(0) { $0 + $1.size }
        for f in files where total > maxBytes && f.url != current {
            try? FileManager.default.removeItem(at: f.url)
            total -= f.size
        }
    }
}
