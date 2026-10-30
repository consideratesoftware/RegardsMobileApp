import Foundation
import Observation
import SwiftUI
import UIKit

/// State behind the Settings Contacts access row (TF-11, ARCHITECTURE.md §10.7
/// and R14's re-entry clause). The row has one state per
/// `ContactsAuthorizationStatus` group:
/// - `.notDetermined`: a button that raises the system prompt, then imports.
/// - `.denied`: a button that opens iOS Settings. The foreground reconcile
///   imports when the user comes back.
/// - `.restricted` (parental controls or device management): status text only,
///   since the user can't change it in iOS Settings and a button would lead
///   nowhere.
/// - `.authorized` and `.limited`: status text only.
///
/// `status` stays nil until the first read, so the row never shows a state the
/// system hasn't confirmed.
@Observable @MainActor
public final class ContactsAccessViewModel {
    public private(set) var status: ContactsAuthorizationStatus?
    /// True after the system request threw, so the tap didn't look dead.
    /// Cleared when a later request succeeds or the status changes.
    public private(set) var requestFailed = false

    public static let requestFailedMessage = "Couldn't ask for Contacts access. Try again."

    private let source: any ContactsSource
    /// Imports what the new access allows. The launch coordinator passes its
    /// foreground reconcile.
    private let reconcile: @MainActor () async -> Void
    private let announce: @MainActor (String) -> Void
    private var isRequesting = false
    /// Numbers each status read, assigned before its `await`. A read that
    /// arrives after a newer one was applied is dropped, so an older answer
    /// can't undo a newer one.
    private var latestReadNumber = 0
    private var appliedReadNumber = 0
    private static let log = RegardsLogger.feature("ContactsAccess")

    public init(
        source: any ContactsSource,
        reconcile: @escaping @MainActor () async -> Void,
        announce: @escaping @MainActor (String) -> Void = { AccessibilityNotification.Announcement($0).post() }
    ) {
        self.source = source
        self.reconcile = reconcile
        self.announce = announce
    }

    /// Reads the current status. Called when Settings appears.
    public func load() async {
        await refresh()
    }

    /// Re-reads the status. Called when the scene becomes active, so a change
    /// made in iOS Settings shows up on return. Announces a change of a status
    /// it already knew; the first read and an unchanged status stay silent.
    public func refresh() async {
        latestReadNumber += 1
        let readNumber = latestReadNumber
        let current = await source.currentAuthorization()
        guard readNumber > appliedReadNumber else { return }
        appliedReadNumber = readNumber
        let previous = status
        status = current
        guard let previous, previous != current else { return }
        requestFailed = false
        switch current {
        case .authorized: announce("Contacts access on")
        case .limited: announce("Contacts access limited")
        case .denied: announce("Contacts access off")
        case .restricted: announce("Contacts access restricted")
        case .notDetermined: break
        }
    }

    /// Raises the system prompt, but only from a known `.notDetermined`: iOS
    /// never re-prompts after a decision, so a request in any other state
    /// would only look like a control that does nothing. The outcome is read
    /// back from the system. Reconciles only if access was granted.
    public func requestAccess() async {
        guard status == .notDetermined, !isRequesting else { return }
        isRequesting = true
        defer { isRequesting = false }
        var requestThrew = false
        do {
            _ = try await source.requestAccess()
            requestFailed = false
        } catch {
            Self.log.error("contacts authorization request failed: \(error, privacy: .private)")
            requestThrew = true
        }
        await refresh()
        if requestThrew, status == .notDetermined {
            requestFailed = true
            announce(Self.requestFailedMessage)
        }
        if status == .authorized || status == .limited {
            await reconcile()
        }
    }

    /// Opens the Regards page in iOS Settings, where Contacts access can be
    /// changed. Takes the `OpenURLAction` so a test can see the URL.
    public func openContactsSettings(using openURL: OpenURLAction) {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}
