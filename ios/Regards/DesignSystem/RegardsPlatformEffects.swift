import SwiftUI

private struct RegardsContactTransitionNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var regardsContactTransitionNamespace: Namespace.ID? {
        get { self[RegardsContactTransitionNamespaceKey.self] }
        set { self[RegardsContactTransitionNamespaceKey.self] = newValue }
    }
}

private struct ContactTransitionSourceModifier: ViewModifier {
    let id: UUID

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.regardsContactTransitionNamespace) private var namespace

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), let namespace, !reduceMotion {
            content.matchedTransitionSource(id: id, in: namespace) { source in
                source
                    .background(RegardsDS.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        } else {
            content
        }
    }
}

private struct ContactTransitionDestinationModifier: ViewModifier {
    let id: UUID

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.regardsContactTransitionNamespace) private var namespace

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), let namespace, !reduceMotion {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            content
        }
    }
}

extension View {
    func regardsContactTransitionSource(id: UUID) -> some View {
        modifier(ContactTransitionSourceModifier(id: id))
    }

    func regardsContactTransitionDestination(id: UUID) -> some View {
        modifier(ContactTransitionDestinationModifier(id: id))
    }
}
