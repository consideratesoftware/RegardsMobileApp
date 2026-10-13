import SwiftUI

/// A compact hour-and-minute picker for a `TimeOfDay`.
///
/// `TimeOfDay` is a wall-clock value with no date, so the picker's `Date` is
/// built on a fixed 2000-01-01 UTC reference and the picker is pinned to UTC.
/// UTC has no DST, so the wall-clock value the user picks is the value
/// stored, whatever zone the device is in. A round trip through the device
/// zone could shift it by an hour on a DST day.
struct TimePickerField: View {
    let title: String
    var hint: String?
    @Binding var time: TimeOfDay

    init(title: String, hint: String? = nil, time: Binding<TimeOfDay>) {
        self.title = title
        self.hint = hint
        self._time = time
    }

    var body: some View {
        DatePicker(
            title,
            selection: Binding(
                get: { time.pickerDate },
                set: { time = TimeOfDay(pickerDate: $0) }
            ),
            displayedComponents: .hourAndMinute
        )
        .labelsHidden()
        .environment(\.timeZone, .gmt)
        .frame(minHeight: 44)
        .accessibilityLabel(title)
        .accessibilityHint(hint ?? "")
    }
}

extension TimeOfDay {
    /// 2000-01-01T00:00:00Z.
    private static let pickerReference = Date(timeIntervalSince1970: 946_684_800)

    private static var pickerCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    /// This time on the fixed UTC reference day. UTC has no DST, so adding
    /// minutes lands on the same wall-clock reading.
    var pickerDate: Date {
        Self.pickerReference.addingTimeInterval(TimeInterval(minutesSinceMidnight * 60))
    }

    /// The same locale-aware text the picker shows ("10:30 PM", or "22:30" in
    /// a 24-hour locale), for labels that sit beside a picker.
    var displayLabel: String {
        pickerDate.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: .gmt))
    }

    /// Reads the hour and minute the picker shows, which are UTC components
    /// because the picker runs in UTC.
    init(pickerDate: Date) {
        let parts = Self.pickerCalendar.dateComponents([.hour, .minute], from: pickerDate)
        self.init(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
    }
}
