import SwiftUI

/// Custom nav bar matching the JSX `<RegardsNavBar>` — wordmark on the left,
/// an action label on the right, then a large 34pt title with an optional
/// muted subtitle ("4 people"). Slightly simpler than SwiftUI's native
/// `.navigationTitle(...)` styling so we can land the mock pixel-faithful.
public struct RegardsNavBar: View {
    public let title: String
    public let subtitle: String?
    public let rightAction: (text: String, handler: (() -> Void)?)?
    public let showWordmark: Bool

    public init(title: String,
                subtitle: String? = nil,
                rightAction: (text: String, handler: (() -> Void)?)? = nil,
                showWordmark: Bool = true) {
        self.title = title
        self.subtitle = subtitle
        self.rightAction = rightAction
        self.showWordmark = showWordmark
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AccessibilityAdaptiveLayout {
                HStack {
                    brand
                    Spacer()
                    rightActionContent
                }
                .frame(minHeight: 24)
            } accessibility: {
                VStack(alignment: .leading, spacing: 6) {
                    brand
                    rightActionContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 24)
            }

            AccessibilityAdaptiveLayout {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    titleText
                    subtitleText
                }
            } accessibility: {
                VStack(alignment: .leading, spacing: 2) {
                    titleText
                    subtitleText
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var brand: some View {
        if showWordmark {
            Wordmark(size: 17, color: RegardsDS.accentInk)
        } else {
            Spacer().frame(height: 17)
        }
    }

    @ViewBuilder
    private var rightActionContent: some View {
        // Render the right action as a `Button` only when the caller actually
        // provided a handler. Otherwise use inert muted text.
        if let rightAction {
            if let handler = rightAction.handler {
                Button {
                    handler()
                } label: {
                    Text(rightAction.text)
                        .font(.body)
                        .foregroundStyle(RegardsDS.accentInk)
                }
                .accessibilityIdentifier("regards-nav.right-action")
            } else {
                Text(rightAction.text)
                    .font(.body)
                    .foregroundStyle(RegardsDS.muted)
                    .accessibilityIdentifier("regards-nav.right-action")
            }
        }
    }

    private var titleText: some View {
        Text(title)
            .font(RegardsFont.largeTitle())
            .foregroundStyle(RegardsDS.ink)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("regards-nav.title")
    }

    @ViewBuilder
    private var subtitleText: some View {
        if let subtitle {
            Text(subtitle)
                .font(.body)
                .foregroundStyle(RegardsDS.muted)
                .accessibilityIdentifier("regards-nav.subtitle")
        }
    }
}

/// Two-option segmented control used for the Overdue / Upcoming toggle.
public struct RegardsSegmentedControl<Tab: Hashable>: View {
    public struct Option: Identifiable {
        public let id: Tab
        public let label: String
        public let count: Int?

        public init(id: Tab, label: String, count: Int? = nil) {
            self.id = id
            self.label = label
            self.count = count
        }
    }

    @Binding var selection: Tab
    let options: [Option]

    public init(selection: Binding<Tab>, options: [Option]) {
        self._selection = selection
        self.options = options
    }

    public var body: some View {
        AccessibilityAdaptiveLayout {
            HStack(spacing: 2) {
                optionButtons
            }
        } accessibility: {
            VStack(spacing: 2) {
                optionButtons
            }
        }
        .padding(3)
        .background(RegardsDS.hairSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private var optionButtons: some View {
        ForEach(options) { option in
            Button {
                selection = option.id
            } label: {
                HStack(spacing: 6) {
                    Text(option.label)
                        .font(.subheadline.weight(selection == option.id ? .semibold : .medium))
                        .foregroundStyle(RegardsDS.ink)
                    if let count = option.count {
                        Text("\(count)")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(
                                    selection == option.id
                                        ? RegardsDS.accentSoft
                                        : RegardsDS.hairSoft
                                )
                            )
                            .foregroundStyle(
                                selection == option.id ? RegardsDS.accentInk : RegardsDS.muted
                            )
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(selection == option.id ? RegardsDS.surface : Color.clear)
                        .shadow(color: selection == option.id ? .black.opacity(0.06) : .clear,
                                radius: 1, y: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(option.label)\(option.count.map { ", \($0)" } ?? "")")
            .accessibilityAddTraits(selection == option.id ? .isSelected : [])
        }
    }
}
