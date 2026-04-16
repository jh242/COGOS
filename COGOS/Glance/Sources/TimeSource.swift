import Foundation

struct TimeSource: GlanceSource {
    let name = "time"
    var enabled = true
    var cacheDuration: TimeInterval = 0
    var tier: GlanceTier = .fixed

    func fetch(context: GlanceContext) async -> String? {
        let f = DateFormatter()
        f.dateFormat = "HH:mm EEE MMM d"
        return f.string(from: context.now)
    }
}
