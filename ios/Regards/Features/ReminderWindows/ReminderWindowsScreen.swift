import SwiftUI

public struct ReminderWindowsScreen: View {
    @State private var window: ReminderWindow
    private let clock: () -> Date

    public init(window: ReminderWindow = .defaultV1(),
                clock: @escaping () -> Date = { Date() }) {
        self._window = State(initialValue: window)
        self.clock = clock
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header

                daysSection
                timeRangesSection
                quietHoursSection
                occasionSection

                Text("All times local · \(window.timezoneIdentifier). DST handled automatically.")
                    .font(.caption)
                    .foregroundStyle(RegardsDS.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 22)

                Color.clear.frame(height: 40)
            }
        }
        .background(RegardsDS.background.ignoresSafeArea())
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("screen.reminder-windows")
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Reminder windows")
                .font(.system(.largeTitle, weight: .bold))
                .foregroundStyle(RegardsDS.ink)
                .accessibilityAddTraits(.isHeader)
            Text("when it's OK to nudge you.")
                .font(RegardsFont.serifItalic(.title3))
                .foregroundStyle(RegardsDS.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    // MARK: - Days

    private var daysSection: some View {
        VStack(spacing: 0) {
            SectionHeader("Days")
            RegardsCard {
                VStack(spacing: 0) {
                    HStack {
                        ForEach(Self.dayLabels, id: \.day) { label in
                            dayPill(
                                letter: label.letter,
                                name: label.name,
                                active: window.allowedDays.contains(label.day)
                            )
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    Hair(inset: 16)
                    Text(daysSummary)
                        .font(.footnote)
                        .foregroundStyle(RegardsDS.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
            }
        }
    }

    private func dayPill(letter: String, name: String, active: Bool) -> some View {
        ZStack {
            Circle()
                // `accentInk` so the white day letter passes AA body contrast.
                .fill(active ? RegardsDS.accentInk : RegardsDS.hairSoft)
                .frame(width: 36, height: 36)
            Text(letter)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(active ? .white : RegardsDS.muted)
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel(active ? "\(name) allowed" : "\(name) not allowed")
    }

    private var daysSummary: String {
        let hasWeekdays = window.allowedDays.contains(.weekdays)
        let hasWeekends = !window.allowedDays.isDisjoint(with: .weekends)
        if hasWeekdays && !hasWeekends { return "Weekdays only. Weekends are yours." }
        if !hasWeekdays && hasWeekends { return "Weekends only." }
        if hasWeekdays && hasWeekends  { return "Any day." }
        return "No days selected."
    }

    // MARK: - Time ranges

    private var timeRangesSection: some View {
        VStack(spacing: 0) {
            SectionHeader("Time ranges · same on every allowed day")
            RegardsCard {
                VStack(spacing: 0) {
                    timelineBar
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    Hair(inset: 16)
                    ForEach(Array(window.allowedTimeRanges.enumerated()), id: \.offset) { idx, range in
                        timeRangeRow(start: format(range.start), end: format(range.end))
                        if idx < window.allowedTimeRanges.count - 1 { Hair(inset: 16) }
                    }
                    Hair(inset: 16)
                    // Stub — Phase 1 wires this to a time-range picker. Muted
                    // so it doesn't look tap-affordable.
                    HStack {
                        Text("+ Add range")
                            .font(.body.weight(.medium))
                            .foregroundStyle(RegardsDS.muted)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
        }
    }

    private var timelineBar: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(RegardsDS.hairSoft)
                ForEach(Array(window.allowedTimeRanges.enumerated()), id: \.offset) { _, range in
                    let startPct = Double(range.start.minutesSinceMidnight) / 1440.0
                    let endPct = Double(range.end.minutesSinceMidnight) / 1440.0
                    RoundedRectangle(cornerRadius: 4)
                        .fill(RegardsDS.accent.opacity(0.85))
                        .frame(width: CGFloat(endPct - startPct) * width)
                        .offset(x: CGFloat(startPct) * width)
                }
                // Real "now" marker — resolved against the window's
                // timezone so the ruler stays honest for users who travel
                // across zones (or when the screen is reviewed from a
                // test harness anchored to a fixed clock).
                Rectangle()
                    .fill(RegardsDS.ink)
                    .frame(width: 2)
                    .offset(x: width * nowFraction)
            }
        }
        .frame(height: 28)
        .accessibilityHidden(true)
    }

    /// 0…1 fraction of the current time through the 24-hour day, resolved in
    /// the window's timezone.
    private var nowFraction: Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = window.timeZone
        let comps = calendar.dateComponents([.hour, .minute], from: clock())
        let minutes = Double((comps.hour ?? 0) * 60 + (comps.minute ?? 0))
        return minutes / 1440.0
    }

    private func timeRangeRow(start: String, end: String) -> some View {
        HStack(spacing: 10) {
            timeChip(start)
            Text("→").foregroundStyle(RegardsDS.muted)
            timeChip(end)
            Spacer()
            // Stub — Phase 1 wires the range editor. Muted until interactive.
            Text("Remove")
                .font(.footnote)
                .foregroundStyle(RegardsDS.muted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func timeChip(_ text: String) -> some View {
        Text(text)
            .font(RegardsFont.mono(.subheadline).weight(.medium))
            .foregroundStyle(RegardsDS.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RegardsDS.hairSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Quiet hours

    private var quietHoursSection: some View {
        VStack(spacing: 0) {
            SectionHeader("Quiet hours · hard override")
            RegardsCard {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Never between")
                            .font(.body.weight(.medium))
                            .foregroundStyle(RegardsDS.ink)
                        Text(quietHoursLabel)
                            .font(RegardsFont.mono(.footnote))
                            .foregroundStyle(RegardsDS.muted)
                    }
                    Spacer()
                    Toggle("", isOn: .constant(window.quietHours != nil))
                        .labelsHidden()
                        // Matches the active day-pill `accentInk` fill on
                        // this same screen so the two accent-colored
                        // controls read as one family.
                        .tint(RegardsDS.accentInk)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
    }

    private var quietHoursLabel: String {
        guard let q = window.quietHours else { return "off" }
        return "\(format(q.start)) → \(format(q.end))"
    }

    // MARK: - Occasion

    private var occasionSection: some View {
        VStack(spacing: 0) {
            SectionHeader("Occasion notifications")
            RegardsCard {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Morning-of time")
                            .font(.body.weight(.medium))
                            .foregroundStyle(RegardsDS.ink)
                        Text("Birthdays + anniversaries, separate from cadence.")
                            .font(.caption)
                            .foregroundStyle(RegardsDS.muted)
                    }
                    Spacer()
                    // Stub — Phase 1 wires the time picker.
                    Text("09:00")
                        .font(RegardsFont.mono(.body).weight(.medium))
                        .foregroundStyle(RegardsDS.muted)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
    }

    // MARK: - Helpers

    private func format(_ time: TimeOfDay) -> String {
        String(format: "%02d:%02d", time.hour, time.minute)
    }

    static let dayLabels: [(day: DayOfWeekMask, letter: String, name: String)] = [
        (.sunday, "S", "Sunday"), (.monday, "M", "Monday"),
        (.tuesday, "T", "Tuesday"), (.wednesday, "W", "Wednesday"),
        (.thursday, "T", "Thursday"), (.friday, "F", "Friday"),
        (.saturday, "S", "Saturday"),
    ]
}
