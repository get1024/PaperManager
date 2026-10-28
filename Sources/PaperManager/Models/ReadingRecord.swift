import Foundation

/// User-confirmed progress, independent of thumbnail navigation or reader choice.
struct ReadingRecord: Codable, Hashable {
    var seconds: TimeInterval = 0
    var progress: Double = 0
    var lastReadAt: Date?

    mutating func add(seconds value: TimeInterval, at date: Date = Date()) {
        guard value.isFinite, value > 0 else { return }
        seconds = max(0, seconds) + value
        lastReadAt = date
    }

    mutating func setProgress(_ value: Double) {
        guard value.isFinite else { return }
        progress = min(1, max(0, value))
        lastReadAt = Date()
    }

    var durationText: String {
        let total = Int(min(max(0, seconds.isFinite ? seconds : 0), 315_360_000))
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }
}
