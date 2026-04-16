import Foundation

struct TimeSource: GlanceSource {
    let name = "time"
    var enabled = true
    var cacheDuration: TimeInterval = 0
    var tier: GlanceTier = .fixed

    func fetch() async -> String? {
        let f = DateFormatter()
        f.dateFormat = "HH:mm EEE MMM d"
        return f.string(from: Date())
    }
}
