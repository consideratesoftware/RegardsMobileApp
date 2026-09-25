import Foundation

/// `UpcomingViewModel`'s display-string formatting — split out of
/// `UpcomingViewModel.swift` to stay under the file-length limit (staged
/// review round 6). Purely presentational: every member here derives a
/// `String`/`Calendar` from a `Date`/`TimeZone` with no repository access and
/// no mutable view-model state, so it reads and tests the same whether it
/// lives in this file or the main one.
extension UpcomingViewModel {

    // MARK: - Formatters (cached per timezone, locale-pinned)
    //
    // DateFormatter construction is slow, the format we want — "h:mm a" with
    // lowercase am/pm — is locale-sensitive without an explicit POSIX pin,
    // and mutating a shared formatter's `timeZone` per call is fragile
    // (Swift 6 strict concurrency would also flag a non-Sendable static
    // written from multiple call sites). One formatter per TZ identifier,
    // cached on first use. `@MainActor` on the caches matches every call
    // site's isolation — static members don't inherit class isolation.

    @MainActor
    private static var timeFormattersByTZ: [String: DateFormatter] = [:]

    @MainActor
    private static var dayHeaderFormattersByTZ: [String: DateFormatter] = [:]

    @MainActor
    private static var calendarsByTZ: [String: Calendar] = [:]

    @MainActor
    static func timeFormatter(for timezone: TimeZone) -> DateFormatter {
        let key = timezone.identifier
        if let existing = timeFormattersByTZ[key] { return existing }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "h:mm a"
        df.amSymbol = "am"
        df.pmSymbol = "pm"
        df.timeZone = timezone
        timeFormattersByTZ[key] = df
        return df
    }

    @MainActor
    static func dayHeaderSuffixFormatter(for timezone: TimeZone) -> DateFormatter {
        let key = timezone.identifier
        if let existing = dayHeaderFormattersByTZ[key] { return existing }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE MMM d"
        df.timeZone = timezone
        dayHeaderFormattersByTZ[key] = df
        return df
    }

    /// Gregorian calendar cached per TZ. Calendar construction is cheaper
    /// than DateFormatter but the per-TZ cache is in the same shape as the
    /// formatters above, and avoiding per-call construction keeps the
    /// grouping pass allocation-free.
    @MainActor
    static func gregorianCalendar(for timezone: TimeZone) -> Calendar {
        let key = timezone.identifier
        if let existing = calendarsByTZ[key] { return existing }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        calendarsByTZ[key] = calendar
        return calendar
    }

    @MainActor
    static func format(time: Date, timezone: TimeZone) -> String {
        timeFormatter(for: timezone).string(from: time).lowercased()
    }

    @MainActor
    static func format(dayHeader date: Date, now: Date, timezone: TimeZone) -> String {
        let calendar = gregorianCalendar(for: timezone)
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let diff = calendar.dateComponents([.day], from: today, to: day).day ?? 0

        let suffix = dayHeaderSuffixFormatter(for: timezone).string(from: date)

        if diff == 0 { return "Today · \(suffix)" }
        if diff == 1 { return "Tomorrow · \(suffix)" }
        return suffix
    }
}
