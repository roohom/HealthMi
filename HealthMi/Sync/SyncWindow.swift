import Foundation

/// One half-open calendar window, shared by cloud reads, migration and local writes.
struct SyncWindow: Codable, Sendable, Equatable {
    let start: Date
    let end: Date
    let cutoff: Date

    init(now: Date, highWater: Date?, days: Int, forceBackfill: Bool,
         timeZone: TimeZone, overlapDays: Int = 1) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        if !forceBackfill, let highWater {
            let anchor = min(highWater, now)
            let overlap = calendar.date(byAdding: .day, value: -overlapDays, to: anchor)!
            start = calendar.startOfDay(for: overlap)
        } else {
            start = calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: today)!
        }
        end = calendar.date(byAdding: .day, value: 1, to: today)!
        cutoff = now
    }

    var startTime: Int { Int(start.timeIntervalSince1970) }
    // Xiaomi's existing adapter uses inclusive seconds. Keep that conversion here.
    var endTime: Int { Int(end.timeIntervalSince1970) - 1 }
}
