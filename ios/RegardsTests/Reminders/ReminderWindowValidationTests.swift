import Foundation
import Testing
@testable import Regards

/// `ReminderWindow` structural validation (decision #28 / R3) and the
/// `TimeOfDay` decode guard (R38). Wrapping allowed ranges are made
/// unrepresentable at validation instead of being silently skipped by the walk.
struct ReminderWindowValidationTests {

    static func range(_ startHour: Int, _ endHour: Int) -> TimeRange {
        TimeRange(start: TimeOfDay(hour: startHour), end: TimeOfDay(hour: endHour))
    }

    // MARK: - ReminderWindow.validate()

    @Test("A normal window validates")
    func defaultWindowIsValid() throws {
        let window = ReminderWindow.defaultV1(timezone: TimeZone(identifier: "Asia/Kolkata")!)
        try window.validate()
        #expect(window.isValid)
    }

    @Test("A wrapping allowed range is rejected (decision #28, R3)")
    func wrappingAllowedRangeRejected() {
        let window = ReminderWindow(
            allowedDays: .weekdays,
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 1))],
            quietHours: nil, timezoneIdentifier: "Asia/Kolkata")
        #expect(!window.isValid)
        #expect(throws: ReminderWindow.ValidationError.self) { try window.validate() }
    }

    @Test("Quiet hours may wrap midnight even though allowed ranges may not")
    func wrappingQuietHoursAllowed() throws {
        let window = ReminderWindow(
            allowedDays: .weekdays,
            allowedTimeRanges: [Self.range(18, 22)],
            quietHours: TimeRange(start: TimeOfDay(hour: 22, minute: 30), end: TimeOfDay(hour: 7, minute: 30)),
            timezoneIdentifier: "Asia/Kolkata")
        try window.validate()
        #expect(window.isValid)
    }

    @Test("Empty allowed days is rejected")
    func noAllowedDaysRejected() {
        let window = ReminderWindow(
            allowedDays: [], allowedTimeRanges: [Self.range(18, 22)],
            quietHours: nil, timezoneIdentifier: "Asia/Kolkata")
        #expect(throws: ReminderWindow.ValidationError.noAllowedDays) { try window.validate() }
        #expect(!window.isValid)
    }

    @Test("Empty allowed ranges is rejected")
    func noAllowedRangesRejected() {
        let window = ReminderWindow(
            allowedDays: .weekdays, allowedTimeRanges: [],
            quietHours: nil, timezoneIdentifier: "Asia/Kolkata")
        #expect(throws: ReminderWindow.ValidationError.noAllowedTimeRanges) { try window.validate() }
        #expect(!window.isValid)
    }

    @Test("A zero-length allowed range is rejected")
    func zeroLengthRangeRejected() {
        let window = ReminderWindow(
            allowedDays: .weekdays,
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 18), end: TimeOfDay(hour: 18))],
            quietHours: nil, timezoneIdentifier: "Asia/Kolkata")
        #expect(!window.isValid)
        #expect(throws: ReminderWindow.ValidationError.self) { try window.validate() }
    }

    // MARK: - TimeOfDay decode guard (R38)

    @Test("Valid TimeOfDay JSON round-trips")
    func timeOfDayRoundTrips() throws {
        let original = TimeOfDay(hour: 13, minute: 45)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TimeOfDay.self, from: data)
        #expect(decoded == original)
    }

    @Test("Out-of-range minutesSinceMidnight throws instead of poisoning calendar math (R38)")
    func timeOfDayRejectsOutOfRange() {
        let overflow = Data(#"{"minutesSinceMidnight":2000}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TimeOfDay.self, from: overflow)
        }
        let negative = Data(#"{"minutesSinceMidnight":-1}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TimeOfDay.self, from: negative)
        }
        // The exact upper boundary (1440) is out of range; 1439 is the last valid.
        let boundary = Data(#"{"minutesSinceMidnight":1440}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TimeOfDay.self, from: boundary)
        }
    }

    @Test("A corrupt TimeRange inside a ReminderWindow fails to decode, not traps")
    func reminderWindowWithCorruptTimeDecodeThrows() {
        // minutesSinceMidnight 5000 would previously flow straight into the walk.
        let json = Data(#"""
        {
          "allowedDays": { "rawValue": 62 },
          "allowedTimeRanges": [
            { "start": { "minutesSinceMidnight": 5000 }, "end": { "minutesSinceMidnight": 1320 } }
          ],
          "timezoneIdentifier": "Asia/Kolkata"
        }
        """#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ReminderWindow.self, from: json)
        }
    }
}
