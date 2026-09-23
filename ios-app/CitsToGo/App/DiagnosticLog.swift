import Foundation

/// Append-only text log in Documents (visible in the Files app, retrievable over USB/Wi-Fi).
/// Rotates at 2 MB to diagnostics.old.log.
final class DiagnosticLog {
    private let url: URL
    private let queue = DispatchQueue(label: "cits.diaglog")
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    init() {
        url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("diagnostics.log")
    }

    func append(_ message: String, at date: Date) {
        let line = "\(formatter.string(from: date)) \(message)\n"
        queue.async { [url] in
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int, size > 2_000_000 {
                let old = url.deletingLastPathComponent().appendingPathComponent("diagnostics.old.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            guard let h = try? FileHandle(forWritingTo: url) else { return }
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
        }
    }
}
