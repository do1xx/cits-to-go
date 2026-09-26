import ActivityKit
import Foundation

/// Live Activity shared between the app and the widget extension.
struct CitsActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Mode: String, Codable, Hashable { case status, signal, warning }
        var mode: Mode
        var title: String            // "Grün", "Stauende", "Verbunden"
        var subtitle: String         // "62 m bis zur Haltelinie · Bahnhofstr."
        var phase: String?           // "go", "caution", "stop", "unknown" for signal mode
        var countdownEnd: Date?      // signal change time (the widget counts down locally)
        var advisoryKmh: Int?
        var packets: Int
        var stations: Int
    }
    var receiverName: String
}
