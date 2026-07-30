# Regards iOS platform adoption

This file records which current Apple platform features Regards adopts, where
they appear, and what happens on the iOS 17 minimum target. It prevents
“modernization” from becoming an unbounded visual rewrite or an accidental
dependency on beta tooling.

## Shipping baseline

- Xcode 26.6 with the iOS 26 SDK is the TestFlight toolchain baseline for this
  refactor.
- iOS 17.0 remains the minimum deployment target.
- iOS 27 and Xcode 27 APIs are beta-only as of this decision and are not used
  on the release branch.
- Availability checks live next to each enhancement. The fallback is part of
  the feature, not deferred cleanup.

Apple references:

- [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
- [Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/)
- [What’s new in SwiftUI](https://developer.apple.com/videos/play/wwdc2025/256/)
- [App Intents](https://developer.apple.com/documentation/appintents)
- [What’s new in App Intents](https://developer.apple.com/videos/play/wwdc2025/260/)
- [iOS and iPadOS release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/)
- [Xcode release notes](https://developer.apple.com/documentation/xcode-release-notes)

## Adoption matrix

| Capability | First used | Regards implementation | Earlier-system behavior |
|---|---:|---|---|
| Native navigation titles and `ContentUnavailableView` | iOS 17 | Overdue, Upcoming, and Contacts use system hierarchy and empty/search states | Baseline; no fallback needed |
| Selection sensory feedback | iOS 17 | One feedback event when the Overdue/Upcoming route changes | Baseline; follows system haptic settings |
| Value-based `Tab` composition | iOS 18 | Typed `RegardsTab` selection and one root per destination | Legacy tagged `TabView` on iOS 17 |
| Search-role tab | iOS 18 | Contacts owns `.searchable`; the system promotes it as the dedicated search destination | Contacts remains a normal tab with embedded system search |
| Adaptive sidebar tabs | iOS 18 | `.sidebarAdaptable` lets the same roots become an iPad sidebar | Standard tab bar on iOS 17 |
| Matched zoom navigation | iOS 18 | Contact rows are stable transition sources; Contact Detail is the destination | Standard navigation push on iOS 17; also used whenever Reduce Motion is on |
| Liquid Glass | iOS 26 | Only the selected Overdue/Upcoming route surface receives an interactive tinted glass effect | Existing opaque Regards surface |
| Scroll-aware tab minimization | iOS 26 | The tab bar minimizes on downward list scroll | Persistent tab bar |
| App Shortcut with immediate foreground mode | iOS 26 | “Open [section] in Regards” opens the app, resets that tab to its root, and submits a typed request to the shared router | No registered shortcut; the full in-app navigation remains |

## Boundaries

Liquid Glass belongs to the functional control layer and system navigation
chrome. Regards content cards stay opaque and readable; glass is not a generic
background material.

The App Shortcut exposes only the four top-level section names. It does not
index contacts, interaction history, notes, or reminder data into system
surfaces.

This refactor deliberately does not add Foundation Models, AlarmKit, widgets,
Control Center controls, Spotlight contact indexing, web content, or network
services. Those either conflict with the privacy model, depend on unfinished
product behavior, or belong to a later scoped TestFlight item.

## Verification

The dedicated PR must show:

1. XcodeGen determinism, strict lint, and a warnings-as-errors build.
2. Unit coverage for repeated and identity-safe App Intent route requests.
3. App Intents metadata extraction during the build.
4. Launch proof on iOS 17 and iOS 26.
5. Focused accessibility regressions for the changed flows plus the staged
   accessibility review. Broad one-run and five-run audits remain owned by the
   post-merge, nightly, and pre-release workflows.
6. Manual VoiceOver, Dynamic Type `accessibility5`, Reduce Motion, and Increased
   Contrast smoke before merge.
