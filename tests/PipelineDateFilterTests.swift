import Foundation

@main
enum PipelineDateFilterTests {
    @MainActor static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Bucharest")!
        let parser = ISO8601DateFormatter()
        let now = parser.date(from: "2026-10-03T20:00:00Z")!
        precondition(PipelineDateFilter.today.includes("2026-10-02T21:00:00Z", now: now, calendar: calendar))
        precondition(!PipelineDateFilter.today.includes("2026-10-02T20:59:59Z", now: now, calendar: calendar))
        precondition(PipelineDateFilter.today.includes("2026-10-03T20:59:59.9999999Z", now: now, calendar: calendar))
        precondition(!PipelineDateFilter.today.includes("2026-10-03T21:00:00Z", now: now, calendar: calendar))
        precondition(!PipelineDateFilter.today.includes("", now: now, calendar: calendar))
        precondition(PipelineDateFilter.all.includes("", now: now, calendar: calendar))
        precondition(PipelineDateFilter.all.includes("2020-01-01T00:00:00Z", now: now, calendar: calendar))
        // The autumn clock change makes this local day 25 hours long.
        let fallBack = parser.date(from: "2026-10-25T12:00:00Z")!
        precondition(PipelineDateFilter.today.includes("2026-10-24T21:00:00Z", now: fallBack, calendar: calendar))
        precondition(PipelineDateFilter.today.includes("2026-10-25T21:59:59Z", now: fallBack, calendar: calendar))
        precondition(!PipelineDateFilter.today.includes("2026-10-25T22:00:00Z", now: fallBack, calendar: calendar))
        print("Pipeline date filters: 10 cases passed")
    }
}
