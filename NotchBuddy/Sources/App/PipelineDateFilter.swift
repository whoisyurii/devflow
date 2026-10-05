import Foundation

@MainActor
enum PipelineDateFilter: String, CaseIterable {
    case today = "Today", all = "All"

    private static let fractional: ISO8601DateFormatter = {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser
    }()
    private static let seconds = ISO8601DateFormatter()

    /// Queue time, using the Mac's calendar day (including DST boundaries).
    func includes(_ timestamp: String, now: Date = .now, calendar: Calendar = .current) -> Bool {
        if self == .all { return true }
        guard let date = Self.fractional.date(from: timestamp) ?? Self.seconds.date(from: timestamp) else { return false }
        return calendar.isDate(date, inSameDayAs: now)
    }
}
