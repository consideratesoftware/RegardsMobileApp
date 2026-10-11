import SwiftUI

/// A compact hour-and-minute picker for a `TimeOfDay`.
///
/// `TimeOfDay` is a wall-clock value with no date, so the picker's `Date` is
/// built on a fixed 2000-01-01 UTC reference and the picker is pinned to UTC.
/// A device-zone round trip would shift the value on a DST day, and trap
/// `TimeOfDay`'s range precondition on a zone with a 30-minute offset.
struct TimePickerField: View {
    let title: String
    @Binding var time: TimeOfDay

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

    /// Reads the hour and minute the picker shows, which are UTC components
    /// because the picker runs in UTC.
    init(pickerDate: Date) {
        let parts = Self.pickerCalendar.dateComponents([.hour, .minute], from: pickerDate)
        self.init(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
    }
}
