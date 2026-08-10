import Foundation

/// Reconciles the persisted `Contact` table against whatever the system
/// Contacts store currently exposes. Runs on every app launch (existing
/// installs), app foreground, and `CNContactStoreDidChange`
/// (ARCHITECTURE.md §7 "Re-import & reconciliation", PR21 / R25 / R35 / R50).
///
/// Reconciliation never deletes a row:
/// - A system contact the store no longer exposes is archived, not deleted,
///   so cadence and interaction history survive for a possible re-add. This
///   only ever happens under `.authorized`, where `fetchAllContacts()` truly
///   enumerates the whole address book — under `.limited`,
///   `fetchAllContacts()` only ever returns the picker-selected subset, so a
///   stored contact outside it isn't "deleted," it's simply not part of the
///   grant, and archiving it would silently hide a still-real contact on
///   every `.authorized → .limited` downgrade (ARCHITECTURE.md §21). Import,
///   refresh, and un-archival still run under `.limited`.
/// - A `systemContactRef` that reappears — e.g. the user adds a previously
///   deselected contact back into a `.limited` selection — is un-archived in
///   place. That's distinct from a genuine delete-then-re-add, which the
///   system gives a brand-new identifier, so it lands as a new row instead
///   (the archived original, and its history, stay exactly where they are).
/// - A row this pass can't decode (R50) is left untouched: it is neither
///   matched, refreshed, nor archived, so a corrupt row is never mistaken for
///   a deleted one.
/// - Under `.authorized`, a ref only archives once it's been missing across
///   **two consecutive `.authorized` passes at least `archiveDebounceFloor`
///   apart** — see the sweep's own comment below for why a single miss (or
///   two rapid ones) isn't enough (ARCHITECTURE.md §21).
public struct ContactsReconciler: Sendable {
    private let source: any ContactsSource
    private let repo: any ContactRepository
    private let clock: @Sendable () -> Date

    public init(
        source: any ContactsSource,
        repo: any ContactRepository,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.source = source
        self.repo = repo
        self.clock = clock
    }

    /// Outcome of one reconciliation pass.
    public struct Result: Sendable {
        public let imported: Int
        public let refreshed: Int
        public let archived: Int
        public let unarchived: Int
        public let unchanged: Int
        public let failed: Int
        /// System refs this pass found missing under `.authorized` (present
        /// in the repo as active, absent from `fetchAllContacts()`) but
        /// didn't yet archive, keyed to the clock time this ref was *first*
        /// observed missing — the two-pass, time-floored debounce below.
        /// Feed this into the next call's `previouslyMissingRefs:` so a ref
        /// that's still missing on a later `.authorized` pass, at least
        /// `archiveDebounceFloor` after it was first seen missing, archives
        /// on that pass. Deliberately excluded from `Equatable` (see the
        /// hand-written `==` below): it's plumbing for the *next* call, not
        /// part of what a test asserting on "this pass's outcome" should
        /// have to spell out every time.
        public let missingRefs: [String: Date]

        public init(
            imported: Int = 0,
            refreshed: Int = 0,
            archived: Int = 0,
            unarchived: Int = 0,
            unchanged: Int = 0,
            failed: Int = 0,
            missingRefs: [String: Date] = [:]
        ) {
            self.imported = imported
            self.refreshed = refreshed
            self.archived = archived
            self.unarchived = unarchived
            self.unchanged = unchanged
            self.failed = failed
            self.missingRefs = missingRefs
        }
    }

    public enum ReconciliationError: Error, Equatable {
        case notAuthorized(ContactsAuthorizationStatus)
    }

    /// Throws `ReconciliationError.notAuthorized` if the source's current
    /// status isn't `.authorized` or `.limited` — `.limited` reconciles
    /// against exactly the picker-selected subset the system exposes, same
    /// as first-launch import.
    ///
    /// `previouslyMissingRefs` is the previous `.authorized` pass's
    /// `Result.missingRefs` (empty for a first-ever call, or after any
    /// non-`.authorized` pass in between — see the archive sweep below for
    /// why only `.authorized` passes count). Threading it through is the
    /// caller's job (`AppLaunchCoordinator` holds it across passes); this
    /// method doesn't retain any state of its own between calls.
    public func reconcile(previouslyMissingRefs: [String: Date] = [:]) async throws -> Result {
        let status = await source.currentAuthorization()
        guard status == .authorized || status == .limited else {
            throw ReconciliationError.notAuthorized(status)
        }

        let systemContacts = try await source.fetchAllContacts()
        // TOCTOU guard: `fetchAllContacts()` can take a while (a full
        // enumeration, even off-pool per R25), and the user can downgrade
        // permissions mid-pass. Re-reading status here and requiring *both*
        // reads say `.authorized` before the archive sweep below means a
        // downgrade landing during the fetch can't mass-archive under a
        // status that was already stale by the time the fetch returned.
        let statusAfterFetch = await source.currentAuthorization()
        let visibleRefs = Set(systemContacts.map(\.identifier))
        let report = try await repo.fetchAllWithDiagnostics()
        var byRef: [String: Contact] = [:]
        byRef.reserveCapacity(report.contacts.count)
        for contact in report.contacts { byRef[contact.systemContactRef] = contact }
        // A corrupted row keeps its ref out of both the import-collision
        // check and the archive sweep below — it's neither "new" nor
        // "deleted", just unreadable, and R50 owns showing that separately.
        let corruptedRefs = Set(report.corrupted.map(\.systemContactRef))

        let now = clock()
        var imported = 0, refreshed = 0, unarchived = 0, unchanged = 0, failed = 0

        for systemContact in systemContacts {
            guard !corruptedRefs.contains(systemContact.identifier) else { continue }
            do {
                if let existing = byRef[systemContact.identifier] {
                    let wasArchived = existing.archivedAt != nil
                    let updated = Self.refreshed(existing, with: systemContact, now: now)
                    guard updated != existing else {
                        unchanged += 1
                        continue
                    }
                    // Field-scoped, not `repo.upsert(updated)`: `updated` is
                    // built from a snapshot read at the start of this pass,
                    // so a whole-row upsert here could revert a concurrent
                    // user write (e.g. a "mark caught up" `lastInteractedAt`
                    // update) landing on this same row mid-pass. See
                    // `updateReconciledFields`'s protocol doc comment.
                    try await repo.updateReconciledFields(
                        id: existing.id,
                        fields: ReconciledContactFields(
                            displayName: updated.displayName,
                            phoneNumbers: updated.phoneNumbers,
                            emailAddresses: updated.emailAddresses,
                            preferredChannelValue: updated.preferredChannelValue,
                            archivedAt: updated.archivedAt
                        )
                    )
                    if wasArchived {
                        unarchived += 1
                    } else {
                        refreshed += 1
                    }
                } else {
                    try await repo.upsert(ContactsImporter.map(systemContact: systemContact, now: now))
                    imported += 1
                }
            } catch {
                failed += 1
                Self.log.error("""
                    reconciliation failed for \(systemContact.identifier, privacy: .private): \
                    \(error, privacy: .private)
                    """)
            }
        }

        // §21: `.limited` exposes only the picker-selected subset, so a
        // stored ref outside `visibleRefs` there isn't evidence of deletion
        // — deselecting a contact from a limited grant must be a no-op, not
        // an archive. Both the pre-fetch and post-fetch reads must agree the
        // pass is `.authorized`, not just the one taken before the
        // (possibly long) enumeration — see the TOCTOU comment above.
        var archived = 0
        var currentMissingRefs: [String: Date] = [:]
        if status == .authorized && statusAfterFetch == .authorized {
            // Round 9: a *single* miss isn't evidence of deletion either.
            // `fetchAllContacts()` reporting a ref absent — whether that's
            // every stored ref (wholesale-empty) or just some of them (e.g.
            // 3-of-5000 visible) — is exactly what a resync-in-progress
            // (iCloud/device restore, Contacts still repopulating) looks
            // like from this API, and a partial read is just as ambiguous
            // as an empty one: nothing distinguishes "this ref was deleted"
            // from "this ref hasn't reappeared in the resync yet" on a
            // single pass.
            //
            // Round 10: "the previous pass also missed it" isn't enough on
            // its own either, if that previous pass happened moments ago —
            // two reconciliation passes seconds apart (e.g. a foreground
            // racing a `CNContactStoreDidChange` for the same event) can
            // both land mid-resync with nothing having had time to
            // reappear, so "two consecutive misses" alone doesn't actually
            // prove the resync is over. `archiveDebounceFloor` requires
            // real wall-clock time between the *first* time a ref was
            // observed missing and the pass that confirms it's still
            // missing — long enough that a resync genuinely in progress has
            // had a real chance to finish and repopulate it. A ref that's
            // missing again after reappearing gets a fresh baseline (its
            // ref simply won't be in `previouslyMissingRefs` that time,
            // same as a first-ever miss), not credit for however long ago
            // its *previous* disappearance was first seen.
            //
            // No per-iteration re-check inside the loop below: the
            // two-point TOCTOU guard above already establishes "authorized
            // at the start of the fetch and authorized right after it," and
            // this loop does no further waiting on the source (only
            // repository writes), so there's no additional window for a
            // downgrade to land inside it.
            for (ref, contact) in byRef where !visibleRefs.contains(ref) && contact.archivedAt == nil {
                let firstMissingAt = previouslyMissingRefs[ref] ?? now
                currentMissingRefs[ref] = firstMissingAt
                guard previouslyMissingRefs[ref] != nil,
                      now.timeIntervalSince(firstMissingAt) >= Self.archiveDebounceFloor else { continue }
                do {
                    try await repo.archive(id: contact.id, at: now)
                    archived += 1
                } catch {
                    failed += 1
                    Self.log.error(
                        "archive failed for \(contact.id, privacy: .private): \(error, privacy: .private)"
                    )
                }
            }
        }

        return Result(
            imported: imported,
            refreshed: refreshed,
            archived: archived,
            unarchived: unarchived,
            unchanged: unchanged,
            failed: failed,
            missingRefs: currentMissingRefs
        )
    }

    /// Applies the system-derived refresh onto a persisted row: name,
    /// phones, emails, `preferredChannelValue` where it would otherwise go
    /// stale, and un-archival if the store exposes the contact again.
    /// `tracked`, `cadenceDays`, `priorityTier`, `preferredChannel`, `notes`,
    /// and group membership are user-owned and never overwritten by a
    /// reconciliation pass. `photoRef` is left alone too: no `ContactsSource`
    /// implementation fetches a photo today (deferred to PR30 with the rest
    /// of the calendar/birthday key additions), so there is nothing here to
    /// refresh it from yet.
    private static func refreshed(
        _ existing: Contact,
        with systemContact: SystemContact,
        now: Date
    ) -> Contact {
        let mapped = ContactsImporter.map(systemContact: systemContact, now: now)
        var updated = existing
        updated.displayName = mapped.displayName
        updated.phoneNumbers = mapped.phoneNumbers
        updated.emailAddresses = mapped.emailAddresses
        // Unconditional, not `if existing.archivedAt != nil`: `systemContact`
        // is only ever passed in for a ref `fetchAllContacts()` currently
        // reports, so reaching this line already means "the store still
        // (or again) exposes this contact" — setting `archivedAt = nil` is
        // the un-archive, and it's a no-op when the row wasn't archived to
        // begin with.
        updated.archivedAt = nil
        updated.preferredChannelValue = Self.redeterminedPreferredChannelValue(
            channel: existing.preferredChannel,
            existingValue: existing.preferredChannelValue,
            refreshedPhones: mapped.phoneNumbers,
            refreshedEmails: mapped.emailAddresses
        )
        return updated
    }

    /// `preferredChannel` (WhatsApp vs. plain call vs. email, etc.) is a
    /// user preference and reconciliation never changes it. But for the two
    /// channels this re-derives — `.phoneCall` and `.email` — a stale
    /// `preferredChannelValue` is a live correctness bug, not cosmetic
    /// drift: a deep link would call or email a number the contact no
    /// longer has. So if the refreshed arrays no longer contain the stored
    /// value, re-derive it with the same rule `ContactsImporter.map` uses
    /// (first E.164-valid phone / first catalog-valid email), clearing it
    /// if nothing still qualifies.
    ///
    /// Every other channel's value is left untouched below, but not all of
    /// them for the same reason. `telegram`/`messenger`/`instagramDM`/
    /// `linkedinMsg`/`discord`/`custom` genuinely aren't phone/email sourced
    /// — `SystemContact` carries no handle for those, so there's nothing to
    /// re-derive from. `sms`, `whatsapp`, and `signal` **are** phone-sourced
    /// (`ChannelCatalog.metadata(for:).valueKind == .phoneE164`, same rule as
    /// `.phoneCall`), and `facetime` is phone-*or*-email-sourced — those four
    /// can go just as stale as `.phoneCall`/`.email` can, by the same
    /// mechanism. Not re-deriving them here is a known scope gap this pass
    /// left for a follow-up, not evidence their values are unrecoverable —
    /// see the test with `.whatsapp` below for exactly this distinction.
    ///
    /// An already-empty value is left empty too: that means no preference
    /// was ever set (the importer's own mapping leaves it blank when
    /// nothing qualifies), and
    /// reconciliation refreshes existing derived state, it doesn't invent a
    /// new preference where the user/importer left none — doing so would
    /// also make an otherwise-untouched contact "changed" on every pass
    /// merely because it has a phone number, breaking idempotence.
    ///
    /// The "still present" check below is an exact string match against
    /// `refreshedPhones`/`refreshedEmails`, which is safe only because
    /// nothing today writes a user-edited `preferredChannelValue` that could
    /// diverge in formatting from what `ContactsImporter.map` would derive
    /// (e.g. a different but equivalent phone rendering). The first PR that
    /// lets a user edit this value directly (`EditContactScreen`, per PR27 /
    /// TF-09) must revisit this: an exact match may no longer reliably
    /// recognize a still-valid, deliberately-edited value as "present."
    private static func redeterminedPreferredChannelValue(
        channel: Channel,
        existingValue: String,
        refreshedPhones: [String],
        refreshedEmails: [String]
    ) -> String {
        guard !existingValue.isEmpty else { return existingValue }
        switch channel {
        case .phoneCall:
            guard !refreshedPhones.contains(existingValue) else { return existingValue }
            return ChannelCatalog.primaryPhone(in: refreshedPhones)
        case .email:
            guard !refreshedEmails.contains(existingValue) else { return existingValue }
            return ChannelCatalog.primaryEmail(in: refreshedEmails)
        default:
            return existingValue
        }
    }

    /// Minimum real time between when a ref was first observed missing and
    /// the `.authorized` pass that confirms it's still missing, before the
    /// archive sweep treats that as a genuine deletion rather than a
    /// resync-in-progress that hasn't had time to repopulate it yet. See
    /// the sweep's own comment for why "two consecutive passes" alone
    /// (round 9) wasn't sufficient — two passes moments apart prove
    /// nothing about whether a resync actually had a chance to finish.
    static let archiveDebounceFloor: TimeInterval = 5 * 60

    private static let log = RegardsLogger.feature("ContactsReconciler")
}

extension ContactsReconciler.Result: Equatable {
    /// Hand-written, not synthesized: compares only the six counters.
    /// `missingRefs` is next-call plumbing (see its doc comment on the
    /// property) — the many `#expect(result == .init(archived: 1))`-shaped
    /// assertions across the test suite predate it and were never meant to
    /// pin which refs happened to be newly-missing on a given pass.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.imported == rhs.imported
            && lhs.refreshed == rhs.refreshed
            && lhs.archived == rhs.archived
            && lhs.unarchived == rhs.unarchived
            && lhs.unchanged == rhs.unchanged
            && lhs.failed == rhs.failed
    }
}
