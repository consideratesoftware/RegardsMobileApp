import SwiftUI

extension ReminderWindowsScreen {
    // MARK: - Days

    var daysSection: some View {
        VStack(spacing: 0) {
            SectionHeader("Days")
            RegardsCard {
                VStack(spacing: 0) {
                    AccessibilityAdaptiveLayout {
                        HStack(spacing: 0) {
                            ForEach(Self.dayLabels, id: \.name) { label in
                                dayPill(label)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                    } accessibility: {
                        VStack(spacing: 0) {
                            ForEach(Self.dayLabels, id: \.name) { label in
                                dayRow(label)
                                Hair(inset: 16)
                            }
                        }
                    }
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

    private func dayPill(_ label: DayLabel) -> some View {
        let active = viewModel.isDayAllowed(label.day)
        return Button {
            viewModel.toggleDay(label.day)
        } label: {
            ZStack {
                Circle()
                    // `background` on `accentInk` is a registered 4.5:1 pair in
                    // both appearances; raw white fails in dark mode.
                    .fill(active ? RegardsDS.accentInk : RegardsDS.hairSoft)
                    .frame(width: pillSize, height: pillSize)
                Text(label.letter)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(active ? RegardsDS.background : RegardsDS.muted)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label.name)
        .accessibilityValue(active ? "allowed" : "not allowed")
    }

    /// The accessibility-size layout: seven circles don't fit, so each day is
    /// a full-width row with its name.
    private func dayRow(_ label: DayLabel) -> some View {
        let active = viewModel.isDayAllowed(label.day)
        return Button {
            viewModel.toggleDay(label.day)
        } label: {
            HStack {
                Text(label.name)
                    .font(.body)
                    .foregroundStyle(RegardsDS.ink)
                Spacer()
                Image(systemName: active ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(active ? RegardsDS.accentInk : RegardsDS.muted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label.name)
        .accessibilityValue(active ? "allowed" : "not allowed")
    }

    private var daysSummary: String {
        let days = viewModel.draft.allowedDays
        switch days {
        case []: return "No days selected."
        case .weekdays: return "Weekdays only. Weekends are yours."
        case .weekends: return "Weekends only."
        case .allDays: return "Any day."
        default:
            let names = Self.dayLabels.filter { days.contains($0.day) }.map(\.name)
            return ListFormatter.localizedString(byJoining: names) + "."
        }
    }

    // MARK: - Time ranges

    var timeRangesSection: some View {
        let ranges = viewModel.draft.allowedTimeRanges
        return VStack(spacing: 0) {
            SectionHeader("Time ranges · same on every allowed day")
            RegardsCard {
                VStack(spacing: 0) {
                    timelineBar
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    Hair(inset: 16)
                    ForEach(Array(ranges.indices), id: \.self) { index in
                        timeRangeRow(index)
                        Hair(inset: 16)
                    }
                    Button {
                        if let message = viewModel.addRange() { speak(message, focus: {}) }
                    } label: {
                        Text("+ Add range")
                            .font(.body.weight(.medium))
                            .foregroundStyle(viewModel.canAddRange ? RegardsDS.accentInk : RegardsDS.muted)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewModel.canAddRange)
                    // The visible "+" is decoration; VoiceOver reads the verb.
                    .accessibilityLabel("Add range")
                    .accessibilityHint(viewModel.canAddRange ? "" : ReminderWindowsViewModel.addRangeUnavailableReason)
                    .accessibilityIdentifier("reminder-windows.add-range")
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
                ForEach(Array(viewModel.draft.allowedTimeRanges.enumerated()), id: \.offset) { _, range in
                    let startPct = Double(range.start.minutesSinceMidnight) / 1440.0
                    let endPct = Double(range.end.minutesSinceMidnight) / 1440.0
                    RoundedRectangle(cornerRadius: 4)
                        .fill(RegardsDS.accent.opacity(0.85))
                        .frame(width: CGFloat(max(endPct - startPct, 0)) * width)
                        .offset(x: CGFloat(startPct) * width)
                }
                // "Now" marker, resolved in the window's own timezone so the
                // ruler stays honest for users who travel across zones.
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
        calendar.timeZone = TimeZone(identifier: viewModel.timezoneIdentifier) ?? .current
        let comps = calendar.dateComponents([.hour, .minute], from: viewModel.clock())
        let minutes = Double((comps.hour ?? 0) * 60 + (comps.minute ?? 0))
        return minutes / 1440.0
    }

    private func timeRangeRow(_ index: Int) -> some View {
        let number = index + 1
        let remove = Button {
            if let message = viewModel.removeRange(at: index) { speak(message, focus: {}) }
        } label: {
            Text("Remove")
                .font(.footnote)
                .foregroundStyle(RegardsDS.accentInk)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Several rows each show "Remove"; the label says which range.
        .accessibilityLabel("Remove range \(number)")
        return AccessibilityAdaptiveLayout {
            HStack(spacing: 10) {
                TimePickerField(title: "Range \(number) start", time: rangeBinding(index, isStart: true))
                // Visual separator: the two pickers' titles already say start and end.
                Text("→")
                    .foregroundStyle(RegardsDS.muted)
                    .accessibilityHidden(true)
                TimePickerField(title: "Range \(number) end", time: rangeBinding(index, isStart: false))
                Spacer()
                if viewModel.canRemoveRange { remove }
            }
            .padding(.horizontal, 16)
        } accessibility: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Range \(number)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(RegardsDS.muted)
                    .accessibilityHidden(true)
                TimePickerField(title: "Range \(number) start", time: rangeBinding(index, isStart: true))
                TimePickerField(title: "Range \(number) end", time: rangeBinding(index, isStart: false))
                if viewModel.canRemoveRange { remove }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func rangeBinding(_ index: Int, isStart: Bool) -> Binding<TimeOfDay> {
        Binding(
            get: {
                let ranges = viewModel.draft.allowedTimeRanges
                guard ranges.indices.contains(index) else { return TimeOfDay(hour: 0) }
                return isStart ? ranges[index].start : ranges[index].end
            },
            set: { viewModel.setRange(at: index, start: isStart ? $0 : nil, end: isStart ? nil : $0) }
        )
    }

    // MARK: - Quiet hours

    var quietHoursSection: some View {
        VStack(spacing: 0) {
            SectionHeader("Quiet hours")
            RegardsCard {
                VStack(spacing: 0) {
                    Toggle(isOn: $viewModel.quietHoursEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Never between")
                                .font(.body.weight(.medium))
                                .foregroundStyle(RegardsDS.ink)
                            Text(quietHoursLabel)
                                .font(RegardsFont.mono(.footnote))
                                .foregroundStyle(RegardsDS.muted)
                        }
                    }
                    // Matches the active day-pill `accentInk` fill on this
                    // screen so the two accent-colored controls read as one family.
                    .tint(RegardsDS.accentInk)
                    // On: the visible words, with "to" for the arrow. Off: the
                    // visible subtitle is "off", which would be read twice
                    // (label, then the switch's own "off" value), so the
                    // label is the feature name instead.
                    .accessibilityLabel(
                        viewModel.quietHoursEnabled ? "Never between, \(quietHoursSpoken)" : "Quiet hours"
                    )
                    .accessibilityIdentifier("reminder-windows.quiet-toggle")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    if let quiet = viewModel.draft.quietHours {
                        Hair(inset: 16)
                        quietPickers(quiet)
                    }
                }
            }
        }
    }

    private func quietPickers(_ quiet: TimeRange) -> some View {
        let start = Binding(get: { quiet.start }, set: { viewModel.setQuietHours(start: $0) })
        let end = Binding(get: { quiet.end }, set: { viewModel.setQuietHours(end: $0) })
        return AccessibilityAdaptiveLayout {
            HStack(spacing: 10) {
                TimePickerField(title: "Quiet hours start", time: start)
                // Visual separator: the two pickers' titles already say start and end.
                Text("→")
                    .foregroundStyle(RegardsDS.muted)
                    .accessibilityHidden(true)
                TimePickerField(title: "Quiet hours end", time: end)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        } accessibility: {
            VStack(alignment: .leading, spacing: 4) {
                TimePickerField(title: "Quiet hours start", time: start)
                TimePickerField(title: "Quiet hours end", time: end)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var quietHoursLabel: String {
        guard let q = viewModel.draft.quietHours else { return "off" }
        return "\(q.start.displayLabel) → \(q.end.displayLabel)"
    }

    private var quietHoursSpoken: String {
        guard let q = viewModel.draft.quietHours else { return "off" }
        return "\(q.start.displayLabel) to \(q.end.displayLabel)"
    }

    // MARK: - Occasion and horizon (global only)

    var occasionSection: some View {
        VStack(spacing: 0) {
            SectionHeader("Occasion notifications")
            RegardsCard {
                AccessibilityAdaptiveLayout {
                    HStack {
                        occasionLabel
                        Spacer()
                        occasionPicker
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                } accessibility: {
                    VStack(alignment: .leading, spacing: 4) {
                        occasionLabel
                        occasionPicker
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
        }
    }

    private var occasionLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Morning-of time")
                .font(.body.weight(.medium))
                .foregroundStyle(RegardsDS.ink)
            Text("Birthdays and anniversaries, separate from cadence.")
                .font(.caption)
                .foregroundStyle(RegardsDS.muted)
        }
        .accessibilityHidden(true)
    }

    // The caption is hidden above (the picker's own title speaks the label)
    // and spoken here as the picker's hint instead.
    private var occasionPicker: some View {
        TimePickerField(
            title: "Morning-of time",
            hint: "Birthdays and anniversaries, separate from cadence.",
            time: $viewModel.draft.occasionTime
        )
    }

    var horizonSection: some View {
        VStack(spacing: 0) {
            SectionHeader("Upcoming horizon")
            RegardsCard {
                VStack(spacing: 0) {
                    ForEach(ReminderWindowsViewModel.horizonChoices, id: \.self) { days in
                        horizonRow(days)
                        if days != ReminderWindowsViewModel.horizonChoices.last { Hair(inset: 16) }
                    }
                }
            }
        }
    }

    private func horizonRow(_ days: Int) -> some View {
        let selected = viewModel.draft.digestHorizonDays == days
        return Button {
            viewModel.draft.digestHorizonDays = days
        } label: {
            HStack {
                Text("\(days) days")
                    .font(.body)
                    .foregroundStyle(RegardsDS.ink)
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? RegardsDS.accentInk : RegardsDS.muted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(days) days")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("reminder-windows.horizon-\(days)")
    }

    // MARK: - Helpers

    private typealias DayLabel = (day: DayOfWeekMask, letter: String, name: String)

    private static let dayLabels: [DayLabel] = [
        (.sunday, "S", "Sunday"), (.monday, "M", "Monday"),
        (.tuesday, "T", "Tuesday"), (.wednesday, "W", "Wednesday"),
        (.thursday, "T", "Thursday"), (.friday, "F", "Friday"),
        (.saturday, "S", "Saturday"),
    ]
}
