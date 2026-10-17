import Foundation

/// The daily hours queued downloads may run in, as minutes after midnight. A window can run past midnight
/// (23:00 to 07:00); one that starts and ends at the same minute is open all day.
struct DownloadWindow: Equatable, Sendable {
    var start: Int
    var end: Int

    static let minutesPerDay = 24 * 60

    init(start: Int, end: Int) {
        self.start = Self.clamp(start)
        self.end = Self.clamp(end)
    }

    private static func clamp(_ minutes: Int) -> Int {
        ((minutes % minutesPerDay) + minutesPerDay) % minutesPerDay
    }

    private static func minutes(of date: Date, in calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard start != end else { return true }
        let now = Self.minutes(of: date, in: calendar)
        return start < end ? (now >= start && now < end) : (now >= start || now < end)
    }

    /// The next time the window opens after `date` (later today, or tomorrow).
    func nextStart(after date: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: date)
        let opening = calendar.date(byAdding: .minute, value: start, to: today) ?? date
        if opening > date { return opening }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? date
        return calendar.date(byAdding: .minute, value: start, to: tomorrow) ?? date
    }

    /// "1:00 AM", in the user's clock style.
    static func timeText(_ minutes: Int, calendar: Calendar = .current) -> String {
        let date = calendar.date(byAdding: .minute, value: minutes, to: calendar.startOfDay(for: Date())) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}
