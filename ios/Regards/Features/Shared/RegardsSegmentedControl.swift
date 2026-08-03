import SwiftUI

/// Two-option route switcher shared by the Overdue and Upcoming tabs.
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
    @Namespace private var selectionTransition
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(selection: Binding<Tab>, options: [Option]) {
        self._selection = selection
        self.options = options
    }

    public var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 2) {
                    optionsLayout
                }
            } else {
                optionsLayout
            }
        }
        .padding(3)
        .background(RegardsDS.hairSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 20)
        .sensoryFeedback(.selection, trigger: selection)
    }

    private var optionsLayout: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 2))
            : AnyLayout(HStackLayout(spacing: 2))

        return layout {
            ForEach(options) { opt in
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        selection = opt.id
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(opt.label)
                            .font(.subheadline.weight(selection == opt.id ? .semibold : .medium))
                            .foregroundStyle(RegardsDS.ink)
                        if let count = opt.count {
                            Text("\(count)")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule().fill(
                                        selection == opt.id
                                            ? RegardsDS.accentSoft
                                            : RegardsDS.hairSoft
                                    )
                                )
                                .foregroundStyle(
                                    selection == opt.id ? RegardsDS.accentInk : RegardsDS.muted
                                )
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .modifier(
                        RegardsSegmentSelectionSurface(
                            isSelected: selection == opt.id,
                            namespace: selectionTransition
                        )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(opt.label)\(opt.count.map { ", \($0)" } ?? "")")
                .accessibilityAddTraits(selection == opt.id ? .isSelected : [])
                .accessibilityIdentifier("regards-segment.\(opt.label.lowercased())")
            }
        }
    }

}

private struct RegardsSegmentSelectionSurface: ViewModifier {
    let isSelected: Bool
    let namespace: Namespace.ID

    @ViewBuilder
    func body(content: Content) -> some View {
        if isSelected {
            if #available(iOS 26.0, *) {
                content
                    .glassEffect(
                        .regular.tint(RegardsDS.accentSoft).interactive(),
                        in: .rect(cornerRadius: 9)
                    )
                    .glassEffectID("regards.segment.selection", in: namespace)
            } else {
                content.background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(RegardsDS.surface)
                        .shadow(color: RegardsDS.ink.opacity(0.06), radius: 1, y: 1)
                }
            }
        } else {
            content
        }
    }
}
