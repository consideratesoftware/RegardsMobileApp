# Regards — Architectural Design Document

**Status:** v1.0 — full rebaseline. Supersedes Draft v0.5 (2026-04-19); the v0.5 text is preserved in git history at tag-worthy commit `aa9bfa7` and earlier.
**Last updated:** 2026-07-01
**Audience:** Claude Code / Claude agent implementation sessions + human reviewers
**Scope:** Native iOS (Swift/SwiftUI) first, native Android (Kotlin/Compose) second. Local-first. No backend. No network code. One-time purchase.

> **Name:** Regards. The word means "warm remembrance sent to someone" — the exact feeling the app is designed to produce. Tagline: *"Send your regards before it's been too long."*

**What changed in v1.0 (read this if you knew v0.5):**

1. The document now describes the code **as built through PR #15 (2026-05-06)** plus every correction needed. Where v0.5 and the code disagreed, each conflict is resolved explicitly here (see §7, §9, §16 decisions #23–#33).
2. Three new operational sections: **§18 Current state ground truth**, **§19 Remediation register** (every known defect with file:line and acceptance criteria), **§20 Release engineering & App Store playbook**, **§21 Maintenance & operations playbook**.
3. §14 contains the rebaselined V1 work packages and acceptance criteria.
   `TESTFLIGHT_PLAN.md` now provides stable execution IDs and gate-based timing;
   the former 2026-08-31 launch anchor is historical.
4. Section numbers **1–17 are stable against v0.5** because code comments cross-reference them (e.g. "§9", "§11"). New material is §18+. Never renumber §1–§17.

**Reading order for a fresh implementation agent:** §18 (where things stand) → §19 (what's broken) → §14 (what to do next, in order) → the spec section for whatever you're implementing (§7/§8/§9/§10/§11) → §17 (working rules). Do not write code before reading §17.

---

## 1. Vision

Regards helps you keep up with the people who matter. It answers one question: **"Who have I been meaning to talk to, but haven't?"**

The user imports their device contacts, marks the ones they actively want to stay in touch with, sets a desired cadence per contact (weekly, monthly, quarterly, yearly, or custom), and picks a preferred way to reach out (call, SMS, WhatsApp, etc.). The app fires local reminders when a cadence elapses — but only during the *reminder windows* the user has chosen (evenings, weekends, lunch breaks — never in the middle of a workday). Tapping a reminder deep-links directly into the right app, with the right contact, ready to go.

## 2. What's in V1

1. Read-only import of device contacts.
2. Per-contact configuration:
   - Whether this contact is tracked.
   - Cadence (e.g., every 2 weeks).
   - Preferred communication channel (from a fixed catalog).
   - Optional: override reminder windows for this specific contact.
3. Global reminder-window preferences (the user picks allowed days + time ranges; reminders only fire inside those windows).
4. A "last talked" timestamp per contact, set by the user via a one-tap "Caught up" button on any reminder or contact detail screen.
5. Local notifications when a contact is overdue, batched into a digest at the next available reminder window.
6. Tap a reminder → deep-link to the preferred communication app, pre-scoped to that contact where the channel supports it. No message prefill.
7. Manual "I talked to X" logging from the contact detail screen.
8. Priority tiers so the user can distinguish inner circle from acquaintances.
9. **Upcoming Reminders view** — a forward-looking list of reminders coming in the next 14 days (or the user's chosen horizon), grouped by day. Lets the user get a head start and mark someone caught up before the reminder fires. Also shows which reminders will collapse into the next digest window.
10. **Birthday & anniversary reminders.** Annual-recurrence reminders read from two on-device sources:
    - **System Contacts**: `CNContact.birthday` and `CNContact.dates` on iOS; `ContactsContract.CommonDataKinds.Event` on Android.
    - **Local device Calendar** (EventKit on iOS, CalendarContract on Android) — optional user-granted permission.
    Fire as morning-of notifications (different default window from cadence reminders), deep-link to the contact's preferred channel. Feb 29 birthdays fall back to Feb 28 in non-leap years.
11. **In-app contact editing (write-back to system Contacts).** Edits write through via partial-field `CNSaveRequest` (iOS) / `ContactsContract` batch operations (Android). System Contacts remain the source of truth; Regards doesn't maintain a private copy. Never deletes, never bulk-edits, never merges system contacts.
12. **In-app duplicate detection & virtual merging.** Likely duplicates are grouped under a single reminder target via a local `ContactGroup`. The merge is **virtual** — system contacts are never modified. Users can unmerge any time. See §7 for data model, §10 for the Merge Duplicates screen.
13. **Home screen & Lock Screen widget.** Small (top-3 overdue), medium (top-5 with channel icons), Lock Screen count-only. Reads from a shared App Group container (iOS) / direct DB read (Android). No network, no new permissions.

## 3. What's explicitly out of V1

- No reading of email, SMS, or messenger history. No OAuth connections.
- No Telegram TDLib. No WhatsApp Web. No Android notification listener. No SMS content observer. No call-log scraping.
- **No OAuth-based calendar integrations — ever.** Users whose birthdays live in Google Calendar can subscribe to the Google Birthdays calendar from their device Calendar app, which we then read via the local Calendar permission — transitive coverage with no network access in our app.
- **No destructive contact operations.** Contact editing is additive and modifies single fields by user intent. Duplicate "merges" are virtual.
- No backend. No cloud sync across devices. No user account.
- No message sending or composing from the app.
- No AI suggestions for what to say.
- No timeline of historical interactions automatically populated from external sources.

These are explicit non-goals in V1 because messaging integrations carry high API/ToS risk, the core value is deliverable without them, and shipping the reminder UX first validates the product. They remain on the roadmap (§14) as V2+ candidates.

## 4. Market position & business model

### Competitive landscape

This space exists but is not saturated, especially at the simple / privacy-forward / friends-and-family end.

| Competitor | Focus | Pricing (April 2026) | What we're not |
|---|---|---|---|
| **Dex** | Professional networking, heavy integrations, AI | $12/month flat | Not doing networking or AI. |
| **Covve** | Business contacts + news | Free up to 20 relationships, $9.99/mo Pro | Narrower focus; no news aggregation. |
| **Social Compass** | Friends & family cadences | Subscription | Closest direct competitor by positioning. |
| **Smart Contact Reminder** (Android) | Basic reminders | Free | Closest feature-wise; weak reminder-window story. |
| **Mesh** (ex-Clay) | Network enrichment | Subscription | Different product entirely. |
| **UpHabit** | Pivoted to sales CRM in 2022 | N/A | Cautionary tale about scope creep. |

> Re-verify pricing during Phase 3 listing prep (§20) — these figures are from April 2026.

### Differentiators

1. **Reminder-window awareness.** Nobody else treats "when is it OK to bug the user" as a first-class design concern. This is the lead pitch.
2. **One-tap deep link into the right app.** Reminders are action-oriented, not to-do lists.
3. **Privacy as a feature.** Local-first, no account, no ads ever, and — uniquely — *provable* (§11).
4. **Native apps on both platforms.**

### Revenue model: one-time purchase, no subscriptions, optional tip jar

The app is local-only with no server costs, so a subscription would be dishonest. Users pay once and get everything.

**Pricing is geo-tiered** using purchasing-power-parity anchors, configured via Apple/Google auto-pricing (configuration, not code):

| Market cluster | Anchor | Examples | Unlock | Coffee tip | Thanks tip | Feature tip |
|---|---|---|---|---|---|---|
| Tier A — high-income | $4.99 | US, CA, UK, AU, NZ, DE, FR, NL, SE, NO, DK, FI, IE, CH, AT, BE, JP, SG, HK, IL, AE | **$4.99** | $2.99 | $6.99 | $14.99 |
| Tier B — upper-middle | $2.99 | PL, CZ, GR, PT, ES, IT, KR, TW, CL, UY | **~$2.99** | $1.99 | $3.99 | $8.99 |
| Tier C — mid | $1.99 | MX, BR, AR, ZA, TR, MY, TH, SA, RO, HU | **~$1.99** | $0.99 | $2.99 | $5.99 |
| Tier D — lower-income | $0.99 | IN, ID, PH, VN, EG, PK, NG, BD, LK, KE, MA | **~$0.99** | — | $1.99 | $3.99 |

| Item | Base (Tier A / US) | Notes |
|---|---|---|
| **Full app unlock** | $4.99 one-time | Single non-consumable IAP. No feature gates. |
| **Free trial** | 7 days | Fully functional. Trial state lives on `UserProfile` (`entitlementTier = trial`), written on first launch; expiry drops to a soft paywall, never deletes data. |
| **Tip: "Coffee"** | $2.99 | Non-consumable. Settings → Support, post-purchase only. No functional effect. |
| **Tip: "Thanks"** | $6.99 | Same. |
| **Tip: "Fund the next feature"** | $14.99 | Same. |

**Entitlement states are exactly three: `free` (trial expired, soft-locked), `trial` (7-day window from first launch), `lifetime` (unlocked).** This supersedes the v0.5 §7 enum which still carried subscription-era tiers; the code (`ios/Regards/Domain/UserProfile.swift`) has been right since PR #2. See decision #23.

**Why this pricing:** $4.99 is below psychological friction in Tier A while signaling quality (~$4.24 net after the App Store Small Business Program's 15% cut). Geo-tiering reflects real purchasing power. Break-even at blended ~$2.50 net is ~215 sales against ~$531 year-one costs. No free tier with contact caps — caps feel punitive; a trial + honest price is cleaner. The tip jar captures supporter goodwill (Overcast, Flighty, and Ivory prove daily users of indie utilities want to pay more). No ads, no analytics SDKs, no trackers, ever.

### Dev cost baseline

| Line item | Cost | Cadence |
|---|---|---|
| Claude Max subscription (~3 mo active dev) | ~$300 | one-time |
| Apple Developer Program | $99 | annual |
| Google Play Console | $25 | one-time |
| Domain | $12 | annual |
| Email (Cloudflare Email Routing) | $0 | — |
| Landing page (GitHub/Cloudflare Pages) | $0 | — |
| Affinity Designer v2 | $70 | one-time |
| Bakery (icon export) | $25 | one-time |
| **Year 1 total** | **~$531** | |
| **Year 2+ ongoing** | **~$111/yr** | |

### Monetization mechanics

- **StoreKit 2** (iOS) / **Play Billing Library 7** (Android). Billing handled entirely by platform; no developer-run server.
- **Entitlement check is on-device.** StoreKit transaction / Play Billing query. "Restore Purchases" button in Settings.
- **Trial:** 7-day grace recorded on `UserProfile` at first launch (iOS and Android identical mechanism — local, honest, trivially bypassable by reinstall, and we accept that; the person willing to reinstall every week was never a customer).
- **Enroll in Apple Small Business Program + Google Play equivalent before launch** (§20 checklist).

### Revenue risks to flag

1. **Contacts permission denial kills the product.** Onboarding must earn it before asking (§10 screen 8).
2. **Niche ceiling.** Plan for a slow burn — Product Hunt, privacy-focused press (Privacy Guides, MacStories), App Store editorial pitch.
3. **No recurring revenue.** Year 2+ income depends on new acquisition; offset by near-zero ongoing costs and the tip jar.

## 5. High-level architecture

```
+---------------------------------------------------------------+
|                         UI layer                              |
|    SwiftUI (iOS)                |    Jetpack Compose (Android)|
+---------------------------------+-----------------------------+
|                   ViewModel / Presentation                    |
+---------------------------------------------------------------+
|                       Domain layer                            |
|                                                               |
|   Contact  |  Cadence  |  ReminderEngine  |  ReminderWindow  |
|   ChannelCatalog  |  DeepLinkBuilder  |  DuplicateDetector   |
|                                                               |
|  Pure Swift / pure Kotlin. No platform APIs. Unit-testable.   |
+---------------------------------------------------------------+
|                       Platform adapters                       |
|                                                               |
|   ContactsSource/Importer  |  NotificationScheduler           |
|   CalendarSource  |  DeepLinker  |  BillingAdapter            |
+---------------------------------------------------------------+
|                         Data layer                            |
|                                                               |
|   SQLite (GRDB on iOS, Room on Android)                       |
|   Encrypted at rest (iOS Data Protection / SQLCipher)         |
+---------------------------------------------------------------+
|                         Platform layer                        |
|   Contacts framework / ContactsContract                       |
|   UNUserNotificationCenter / NotificationManager              |
|   UIApplication.open / Intent.ACTION_VIEW                     |
|   StoreKit 2 / Play Billing                                   |
+---------------------------------------------------------------+
```

Two layer boundaries are **CI-enforced** by grep guards in `.github/workflows/guards.yml`:

1. **Domain purity.** `ios/Regards/Domain/**` must be pure Swift: no imports from `UIKit`, `SwiftUI`, `Contacts`, `EventKit`, `UserNotifications`, `GRDB`, `StoreKit`, or `Network`, including preconcurrency and selective imports. Platform-dependent code belongs in `Platform/` or `Data/`.
2. **No networking anywhere in app sources.** The shared privacy guard scans `ios/Regards` for *call sites* of `URLSession*`, `NW{Connection,Endpoint,Listener,PathMonitor,Interface,Path}`, `URLRequest`, `URLProtocol`, `NSURLConnection`, `CFSocket*`, and `CF{Read,Write}Stream*`. The pattern matches `Foo.` or `Foo(`, so those names may appear as bare tokens in user-facing copy without tripping the gate.

**One additional architectural service, introduced in Phase 1C (not in v0.5):** the **SchedulingPass** — an app-level orchestrator that owns the write path from domain decisions to persisted `ScheduledReminder` rows to OS notifications. The ReminderEngine stays a pure function; SchedulingPass is the only component allowed to (a) compute effective inputs (group max-interaction, effective window), (b) upsert `ScheduledReminder` rows, and (c) sync the pending set to `UNUserNotificationCenter` via the NotificationScheduler adapter. Every UI surface *reads* reminders from the DB; nothing but SchedulingPass *writes* them. See §9a.

## 6. Tech stack

### iOS

- **Language:** Swift 6, `SWIFT_STRICT_CONCURRENCY: complete`, warnings-as-errors in Debug and Release.
- **UI:** SwiftUI, iOS 17.0 minimum target. The compatibility tiers are explicit:
  iOS 17 keeps the complete baseline experience; iOS 18 adds value-based tabs,
  the search-role destination, adaptive sidebar tabs, and matched zoom
  navigation; iOS 26 adds Liquid Glass to the functional control layer and
  scroll-aware tab-bar minimization. Every newer API has an availability-gated
  fallback in the same view hierarchy (decision #40).
- **System experiences:** App Intents / App Shortcuts, currently limited to an
  iOS 26 local “open section” shortcut. It routes through the same typed tab
  router as in-app navigation and exposes no contact data.
- **Persistence:** GRDB.swift (SPM, declared `from: "6.29.0"` and resolved via
  the committed `Package.resolved`; R21 closed).
- **Async:** Swift Concurrency. ViewModels are `@MainActor @Observable`.
- **Notifications:** `UNUserNotificationCenter`, non-repeating `UNCalendarNotificationTrigger`.
- **Contacts:** `Contacts.framework` behind the `ContactsSource` protocol (`ios/Regards/Platform/Contacts/`).
- **Calendar:** EventKit behind a `CalendarSource` protocol (Phase 1D).
- **Deep linking out:** `UIApplication.open(_:)` behind a `DeepLinker` protocol; schemes declared in `LSApplicationQueriesSchemes` only where universal links don't exist (§8).
- **Billing:** StoreKit 2 (Phase 2).
- **Project generation:** XcodeGen from `ios/project.yml`. **Never hand-edit `Regards.xcodeproj`** — CI enforces determinism (`xcodegen generate && git diff --exit-code`).
- **Toolchain:** CI pins the runner's stable Xcode (currently 26.6; simulator pinned to iPhone 17 Pro with the latest installed iOS runtime). `project.yml` declares `xcodeVersion: "26.0"` for local work on Xcode 26. Before Phase 3, pin CI to the exact Xcode version used for App Store submission, run the full suite on the current iOS beta, and record the choice in the decisions log (see §21 "OS-beta season").
- **Lint:** SwiftLint `--strict`. Custom rule `button_requires_accessibility` flags `Button { Image/Spacer/EmptyView }` without `.accessibilityLabel`.

### Android (follow-on port; scaffold landed — see `ANDROID_PORT.md`, decision #41)

- Kotlin 2.x, Jetpack Compose + Material 3, Room + SQLCipher, Coroutines/Flow, `NotificationManagerCompat` + `AlarmManager.setExactAndAllowWhileIdle` (WorkManager fallback if exact alarms refused), ContactsContract, Play Billing 7. Min SDK 28.
- The Swift domain layer + its test suite is the porting reference. No KMP — we port, not share (decision #2, #20).

### Shared

- This document is the single source of truth. The v0.5 plan for a sibling
  `DOMAIN_MODEL.md` is **dropped** (decision #24): with the Swift domain layer
  + tests as the executable spec, a third artifact would drift. The stale
  README references were removed and root-document link checking now prevents
  their return (R19 closed).

## 7. Data model

All local SQLite. No cloud, no sync. **This section describes the schema as migration `v1` created it** (`ios/Regards/Data/DatabaseMigrator.swift`), plus the `v2` migration Phase 1 adds. Where v0.5 differed from the shipped `v1`, the shipped code wins and the difference is called out.

```
Contact
  id: UUID (primary key)
  systemContactRef: TEXT UNIQUE     -- platform-native identifier
  displayName: TEXT
  photoRef: TEXT?                   -- derived from system contact; cached locally
  tracked: BOOLEAN
  cadenceDays: INTEGER?             -- null if tracked == false
  priorityTier: INTEGER (0-3)       -- 0 = inner circle
  preferredChannel: TEXT            -- enum, see ChannelCatalog
  preferredChannelValue: TEXT       -- resolved at config time
  reminderWindowOverride: TEXT?     -- JSON ReminderWindow; null = use global
  lastInteractedAt: INTEGER?        -- epoch seconds. Source of truth.
  notes: TEXT                       -- Regards-local; NEVER written back to system Contacts
  contactGroupId: UUID?             -> ContactGroup.id (ON DELETE SET NULL)
  createdAt: INTEGER
  archivedAt: INTEGER?
  -- v2 adds:
  phonesJson: TEXT                  -- JSON array of all phone numbers (E.164-normalized where parseable), captured at import/reconcile
  emailsJson: TEXT                  -- JSON array of all emails (lowercased), captured at import/reconcile

ContactGroup                        -- virtual merge targets; NEVER written to system Contacts
  id: UUID (primary key)
  displayName: TEXT
  primaryContactId: UUID            -> Contact.id (the "face": photo, channel)
  createdAt: INTEGER
  createdBy: TEXT                   -- 'user' | 'suggestion_accepted' (local-only quality signal)

ReminderWindow (global prefs, single row)
  id: INTEGER PRIMARY KEY CHECK (id = 1)
  allowedDaysMask: INTEGER          -- bitmask, Sun=1, Mon=2, ... Sat=64
  allowedTimeRangesJson: TEXT       -- e.g., [{start:"18:00", end:"22:00"}]
  quietHoursJson: TEXT              -- absolute "never between X and Y" override; wrap-aware (22:00→07:00 legal)
  timezone: TEXT                    -- IANA, defaults to device
  -- v2 adds:
  occasionTime: TEXT                -- persisted/validated "HH:mm", default "09:00"; no production scheduler consumes it yet
  digestHorizonDays: INTEGER        -- Upcoming view horizon (7/14/30), default 14

ScheduledReminder
  id: UUID
  contactId: UUID -> Contact.id (ON DELETE CASCADE)
                                    -- for a virtually merged group this is the PRIMARY contact's id
  kind: TEXT                        -- 'cadence' | 'birthday' | 'anniversary' | 'custom_occasion'
  occasionDate: TEXT?               -- ISO "MM-DD" for annual kinds; null for cadence
  occasionLabel: TEXT?              -- free-text for anniversaries/custom
  scheduledFor: INTEGER             -- epoch seconds, ALREADY SNAPPED to an allowed-window slot start (§9).
                                     -- Caveat: §14 PR22's DB-only `SchedulingPass` stub (TF-04) is the one
                                     -- exception — its `snooze`/`caughtUp` writes are plain calendar-day
                                     -- arithmetic with no `ReminderWindow`/`ReminderEngine` involved at all,
                                     -- so this invariant does not hold for rows it writes until PR25 folds
                                     -- it into the real engine.
  osNotificationId: TEXT            -- UNUserNotificationCenter identifier for cancel/replace
  state: TEXT                       -- pending | fired | cancelled | user_caught_up

  -- We do NOT persist birthdays/anniversaries ourselves. They are re-read from
  -- system Contacts + local Calendar on each scheduling pass ("system contacts
  -- are the source of truth", no sync drift).

InteractionLog
  id: UUID
  contactId: UUID -> Contact.id (ON DELETE CASCADE)
  occurredAt: INTEGER
  source: TEXT                      -- 'manual' | 'reminder_tap' | 'reminder_caught_up'
  channel: TEXT?

UserProfile (single row)
  id INTEGER PRIMARY KEY CHECK (id = 1)
  onboardingCompletedAt: INTEGER?
  entitlementTier: TEXT             -- 'free' | 'trial' | 'lifetime'   (decision #23; v0.5's plus_monthly/plus_annual are dead)
  entitlementRefreshedAt: INTEGER
  -- v2 adds:
  trialStartedAt: INTEGER?          -- epoch seconds; set on first launch; trial = trialStartedAt + 7d > now
```

**Key indexes (as built in v1):** `Contact(tracked, archivedAt)`, `Contact(contactGroupId)`, `ScheduledReminder(state, scheduledFor)`. `Contact(systemContactRef)` is covered by the implicit unique-constraint index from `.unique()` — deliberate, don't add a duplicate explicit index.

**Foreign-key behavior (as built, keep):** `ScheduledReminder.contactId` and `InteractionLog.contactId` cascade-delete with their contact; `Contact.contactGroupId` nulls out when its group is deleted (unmerge = delete group row, members revert to ungrouped).

**Migration policy:** GRDB `DatabaseMigrator`, append-only registrations, each migration named `vN`. Never edit a shipped migration. `v2` (Phase 1B, PR20–PR23) adds the columns marked above. Migration tests round-trip every table through fresh-create and v1→v2 upgrade paths (§13).

**Re-import & reconciliation (Phase 1B, PR21 — spec unchanged from v0.5):** on every app launch/foreground + on `CNContactStoreDidChange`, reconcile against `systemContactRef`:
- New system contacts → import as `tracked=false`.
- Deleted system contacts → set `archivedAt` (never hard-delete; cadence/log history stays for potential re-add). **`.authorized` only.** Under `.limited`, `fetchAllContacts()` returns just the picker-selected subset, so a stored ref outside it isn't evidence of deletion — deselecting a contact from a limited grant (or an `.authorized → .limited` downgrade) must be a no-op, never an archive (§21). A ref missing from a single `.authorized` fetch — whether that's the *whole* stored address book (a wholesale-empty read) or only part of it (e.g. 3-of-5000 visible) — is equally ambiguous: both shapes are indistinguishable from Contacts still repopulating mid-restore (an iCloud/device backup resync in progress, §21) on that one pass alone. A ref only archives once it's been missing on **two consecutive `.authorized` passes at least `ContactsReconciler.archiveDebounceFloor` (5 minutes) apart** (`ContactsReconciler.reconcile(previouslyMissingRefs:)`, threaded pass-to-pass, timestamp included, by `AppLaunchCoordinator`). Two consecutive misses alone isn't sufficient on its own: a foreground racing the `CNContactStoreDidChange` notification it woke up to handle can land two passes moments apart, both mid-resync, with nothing having had any real chance to reappear — "two passes" doesn't prove a resync had time to finish, only real elapsed time does. The floor is measured from the pass that *first* observed a ref missing, not from whichever pass most recently re-confirmed it, so a ref doesn't need two passes exactly 5 minutes apart — any later `.authorized` pass that still misses it, once 5 minutes have passed since the first miss, archives it. A `.limited` pass (or any failed pass) in between breaks the chain and a subsequent miss starts a fresh baseline. That per-ref "first seen missing" timestamp survives a relaunch: `AppLaunchCoordinator` persists it (hashed by `ContactRefHasher.hash(_:)`, never the raw `systemContactRef`) to `MissingContactRefStore`, a sidecar JSON file in Application Support under `NSFileProtectionComplete`, separate from the GRDB database — loaded in `start()`, saved after every pass. Without that, two consecutive `.authorized` passes 5+ minutes apart rarely land inside one process lifetime on iOS, and a genuine deletion could go unarchived indefinitely. Import, refresh, and un-archival still run under `.limited`.
- Changed contacts → refresh `displayName`, `phonesJson`, and `emailsJson` via a field-scoped write that touches only those columns (plus `preferredChannelValue` and `archivedAt`) — never a whole-row overwrite, so a concurrent user write to any other column (e.g. `lastInteractedAt` from marking caught-up) can't be silently reverted by a reconcile pass racing it. **`photoRef` refresh is deferred to PR30**, which owns adding the `CNContactImageDataKey` fetch alongside the birthday/date key additions — no `ContactsSource` implementation reads a photo before then, so PR21 has nothing to refresh it from.
- The shipped `ContactsImporter` (PR #10) is first-launch/additive only — that's the documented gap PR21 closes, not a bug in what shipped.

**Write-back (Phase 1D, PR27):** partial-field `CNSaveRequest` — only fields the user explicitly edited. `notes` never write back. Re-fetch after save so Regards reflects what the system store accepted.

**Duplicate-detection heuristic (as built + v2 inputs):** candidate pairs where (a) normalized display names match (case/diacritic-insensitive), (b) any phone matches on the **last-10-digit key**, or (c) any lowercased email matches. **The last-10 rule is a deliberate deviation from v0.5's "E.164 match"** (decision #25): it treats `+1 (555) 123-4567` and `555.123.4567` as the same line without a phone-number parsing dependency; the false-positive window (two countries sharing 10 trailing digits *within one person's address book*) is negligible. Confidence ranking (decision #26, resolves the shipped docstring/behavior mismatch): **phone match = high** (with or without name similarity — a shared line is almost always the same person), **email match = medium** (families share emails), **name-only = low**. Nothing auto-merges; the user confirms each pair. Detector inputs come from `phonesJson`/`emailsJson` (all handles), not just `preferredChannelValue` — the shipped Phase 0 wiring that feeds only one handle per contact is gap R12.

**Scheduling under virtual merges (unchanged spec, unimplemented until PR28):** the group is the reminder target when `contactGroupId` is non-null. `effectiveLastInteractedAt` = max across members (interacting with any member counts). Preferred channel and face come from `primaryContactId`. `ScheduledReminder.contactId` = the primary contact's id; SchedulingPass guarantees at most one pending cadence reminder per group. Overdue/Upcoming render one row per group; All Contacts still shows members individually with a group indicator.

## 8. Channel catalog & deep linking

V1 ships this fixed catalog. Each entry defines (a) what the user supplies, (b) validation, (c) the link built. `ChannelCatalog` (pure domain) owns validation + metadata; `DeepLinkBuilder` (pure domain) builds URLs; the `DeepLinker` platform adapter (Phase 1C) opens them.

| Channel | User supplies | Validation | Link (both platforms unless noted) | Notes |
|---|---|---|---|---|
| `phone_call` | phone | E.164-parseable | `tel:+15551234567` | Always works. |
| `sms` | phone | E.164-parseable | `sms:+15551234567` | iOS routes to iMessage where enabled. |
| `facetime` | phone **or email** | phone rule OR RFC-5322 | `facetime:+15551234567` / `facetime:alex@example.com` | iOS only; hidden on Android. Email form passes through verbatim. |
| `email` | email | RFC 5322 | `mailto:alex@example.com` | |
| `whatsapp` | phone | E.164, strip `+` | `https://wa.me/15551234567` | Universal link; graceful web fallback. |
| `telegram` | @handle | handle regex, leading `@` stripped before validation | `https://t.me/alexc` | |
| `signal` | phone | E.164 | `https://signal.me/#p/+15551234567` | Number must be registered with Signal; we warn in the picker UI. |
| `messenger` | handle **or m.me URL** | handle regex OR `https://m.me/...` URL, normalized to the handle | `https://m.me/alexc` | |
| `instagram_dm` | @handle | handle regex (strip `@`) | `https://ig.me/m/alexc` | |
| `linkedin_msg` | vanity handle or profile URL | | `https://linkedin.com/in/alex-chen` | Opens profile; user taps Message. |
| `discord` | username + optional user ID | | `discord://discord.com/users/USER_ID` if ID known, else `discord://` | IDs aren't discoverable; without one we open Discord generically and surface the username in the notification/detail UI. |
| `in_person` | — | — | none | Reminder fires with no link. |
| `custom` | arbitrary URL | any URL with a scheme | that URL | Escape hatch (Slack `slack://`, Teams, Matrix…). |

**Validation contract (decision #27):** for every link-bearing channel, validation answers "can `DeepLinkBuilder` produce a well-formed URL from this value?" — nothing more. If validation passes, `build` must return non-nil; if it returns nil for a validated value, that's a bug (add a property test asserting `isValid(v) ⟹ build(v) != nil` per link-bearing channel, R2/R7 acceptance). `in_person` is the explicit no-link exception: its empty value is valid and `build` returns nil by design.

**iOS `LSApplicationQueriesSchemes`:** keep the array **minimal**, populated in PR26, containing only schemes we actually pass to `canOpenURL`: `discord` (and nothing else at launch — wa.me/t.me/ig.me/m.me/signal.me are HTTPS universal links with web fallback, so we open them without querying; `tel:`/`sms:`/`mailto:`/`facetime:` we open directly without a capability query). Every addition to this array is a privacy-adjacent diff: it discloses which apps we probe for. Justify each in the PR description.

**Android fallback:** `resolveActivity` before launching; on null offer the https fallback in a toast.

**Adding channels in V1.1+** requires an app update (scheme declarations are static). Acceptable.

## 9. Reminder-window engine

The second differentiator. Everything below is the **contract**; `ios/Regards/Domain/Reminders/ReminderEngine.swift` implements it (with the P0 defects in §19 open until PR16 lands).

### Global reminder window configuration

The user picks:
- Allowed **days of the week** (bitmask).
- Allowed **time ranges**, same ranges for every allowed day in V1. **Allowed ranges must not wrap midnight** (decision #28): the editor UI never offers a wrapping range, and `ReminderWindow` validation rejects one (`start < end` strictly). Wrap support exists **only** for quiet hours, where "22:00 → 07:00" is the natural shape. The shipped walk silently skips wrapping allowed ranges — validation makes that state unrepresentable instead (R3).
- **Timezone:** IANA id, defaults to device; all engine math runs in this zone.
- **Quiet hours:** absolute override, wrap-aware, beats every allowed range.

### Per-contact override

`Contact.reminderWindowOverride` (full `ReminderWindow` JSON) replaces the global window when non-null. Resolution happens in **one** place — SchedulingPass computes `effectiveWindow = contact.reminderWindowOverride ?? global` and passes it down; the engine never reaches around its inputs. (R9, now split: the **global** half is closed — `AppRuntime` composes `UpcomingViewModel` with the persisted window, so the view model no longer hardcodes `.defaultV1()`. The **per-contact override** half stays open, along with live refresh when the stored window changes; both land with the reminder-window editor and SchedulingPass.)

### Scheduling algorithm

```
overdueAt  = (effectiveLastInteractedAt ?? contact.createdAt) + cadenceDays * 86400
target     = max(now, overdueAt)
slot       = nextAllowedSlot(                           // nil if window has zero capacity
               window,
               from: target,
               includingContainingSlot: overdueAt <= now)
scheduledFor = slot.start                                // snapped to slot START (see Batching)
```

**Contract points, each resolving a shipped defect or ambiguity:**

1. **Wall-clock correctness (R1, the P0).** `nextAllowedSlot` must materialize candidate times with wall-clock APIs — `calendar.date(bySettingHour:minute:second:of:)` or `calendar.nextDate(after:matching:)` — never `startOfDay + N minutes`. Minute-addition is elapsed time: on spring-forward days it lands 60 min late (07:00 window → fires 08:00, *outside* the window); on fall-back days 60 min early (→ 06:00, *before* the user said it's OK). Firing outside the user's declared window is the one product promise we can't break. After materializing, **re-validate** the instant against the window and quiet hours; on a DST day where the slot start doesn't exist (02:30 in a skipped hour), take the earliest existing instant inside the range, else walk on.
2. **Degenerate windows are unrepresentable + defensively handled (R4).** `nextAllowedSlot` returns `Date?`; nil means "this window can never fire" (no days, no ranges, or quiet hours swallow everything). The window editor refuses to save such a config (inline error), and SchedulingPass treats nil as "skip + surface a Settings badge", never "fire anyway". The shipped behavior — returning the input date unchanged, i.e. scheduling at a disallowed instant — is the worst of the options; kill it.
3. **Never-contacted anchor (decision #29, R8).** `effectiveLastInteractedAt ?? createdAt` — a newly tracked contact becomes due one full cadence after you started tracking them, not instantly. Rationale: the user just triaged this person during import/onboarding; "overdue immediately" turns the first-run Overdue screen into a wall of red and teaches users to ignore it. The engine's shipped "never contacted = due now" branch loses to the ViewModels' `?? createdAt`; unify on the VM semantics in the engine and delete the divergence.
4. **Occasion same-day rule (R5).** If today is the occasion and `occasionTime` has passed, fire at the next possible moment **today** (subject to quiet hours only — occasions ignore allowed-day/range gating by design, they're morning-of events). The shipped `nextOccasionOccurrence` rolls a same-day-but-late occasion a full year forward; a user who installs at noon on Mom's birthday must still get the birthday nudge.
5. **Batching = slot-start snapping (decision #30, R6).** All reminders landing in the same window slot share the **same `scheduledFor` = slot start**, so digest grouping is exact-equality by construction and one OS notification per slot exists (`osNotificationId = "digest-{slotStartEpoch}"` for the batch; single-contact slots use `"contact-{uuid}-{kind}"`). Digest copy: *"3 people are overdue: Leia, Luke, Padmé."* Tap → Overdue view. Per-contact nags are the #1 reason this category gets silenced.
   - An already-overdue contact may join the slot currently in progress; the past slot start represents an immediate delivery and a stable digest identity.
   - A contact whose cadence expires later inside the current slot must walk to the next slot start. It may never fire before `overdueAt` (R48).
6. **No double-up.** If a contact has both an overdue cadence reminder and an occasion today, the occasion wins; the cadence reminder is marked `user_caught_up` when the user acts on the occasion (a birthday call counts as staying in touch). **Known Phase-0 deviation:** `UpcomingViewModel` computes cadence rows independently of the persisted occasion rows it reads, so it does not apply this rule and a same-day pair can appear twice in Upcoming. `SchedulingPass` is the sole idempotent reminder writer and owns the suppression (PR25 / TF-07, R6); the deviation is documented at the `buildRows` call site and closes there, not in the view model.

### Re-evaluation triggers (all route through SchedulingPass, §9a)

- "Caught up" → log interaction, set `lastInteractedAt`, cancel pending reminder(s) for the contact/group, reschedule.
- Snooze (1 week) → push the pending reminder's `scheduledFor` to `nextAllowedSlot(from: firedAt + 7d, includingContainingSlot: false)`; state stays `pending`; no interaction is logged and `lastInteractedAt` does **not** move (decision #31). `includingContainingSlot: false`, not the default `true`: a snooze target is always a future instant, never "the slot already in progress," so the walk must land on the next slot start strictly after it, not snap backward into a slot that could be at or before `firedAt + 7d`.
- Cadence/channel/override change → cancel & reschedule that contact.
- Global window change → bulk-reschedule all pending (bounded by tracked count; cheap).
- App launch/foreground → full reconcile: re-read Contacts/Calendar occasions, recompute all pending, cancel orphaned OS notifications (any `UNNotificationRequest` whose id isn't in the pending set), verify times still in-window (TZ change, DST).
- Notification fired → mark row `fired`; when the user acts (tap/caught-up action), advance per its semantics; occasions re-schedule for next year.

### Annual recurrence (birthdays & anniversaries)

Sources, merged per contact (Contacts wins over Calendar): `CNContact.birthday` + `CNContact.dates` (labels → `anniversary`/`custom_occasion`); EventKit birthday-calendar events when Calendar permission granted. Feb 29 → Feb 28 in non-leap years (shipped, tested). Occasions fire at `ReminderWindow.occasionTime` (default 09:00) — a *separate* default from cadence windows because the user needs the whole day to act. Copy: *"🎂 It's Leia's birthday today — open WhatsApp?"* with the contact's deep link.

### Platform nuance

**iOS:** non-repeating `UNCalendarNotificationTrigger`; re-schedule after each fire. The 64-pending cap is respected by construction: one notification per slot (digests) + occasion notifications; SchedulingPass keeps only the next fire per contact/group. If the pending set would exceed 60, schedule the nearest 60 and reconcile forward on each launch (defensive; realistic users won't hit it).

**Android (port):** `AlarmManager.setExactAndAllowWhileIdle` with `SCHEDULE_EXACT_ALARM`; graceful WorkManager fallback (5–15 min drift acceptable).

## 9a. SchedulingPass — the orchestrator (new in v1.0)

Single `actor SchedulingPass` (App layer, constructed in `AppRuntime.init` alongside `environment`, resolving its wall-clock math through the persisted reminder window's own `timeZone` rather than `AppRuntime`'s device-derived `userCalendar` — §14 PR22), the only writer of `ScheduledReminder` rows and OS notifications.

```
protocol NotificationScheduling: Sendable {          // Platform/Notifications
  func requestAuthorization() async throws -> Bool
  func pendingIdentifiers() async -> Set<String>
  func schedule(_ requests: [ReminderNotificationRequest]) async throws
  func cancel(identifiers: [String]) async
}

actor SchedulingPass {
  func runFull() async            // launch/foreground/window-change reconcile
  func run(for contactId: UUID) async   // targeted: caught-up, cadence edit, snooze
}
```

`runFull()` algorithm: fetch tracked+unarchived contacts, resolve groups (one target per group, `effectiveLastInteractedAt` = member max), resolve effective windows, read occasion dates from ContactsSource/CalendarSource, run the pure engine per target, snap to slots, diff against existing `pending` rows (upsert changed, cancel orphans), then diff `osNotificationId`s against `pendingIdentifiers()` and schedule/cancel the difference. Idempotent: running it twice in a row is a no-op. Unit-tested with fake repositories + fake scheduler (order-independent assertions); this is the component where most future bugs will live, so its tests are the highest-value suite after the engine's (§13).

UI reads: Overdue/Upcoming ViewModels observe `ScheduledReminder` + `Contact` via GRDB `ValueObservation` (reactive, replaces Phase 0's on-the-fly derivation — R10). The Upcoming screen is then exactly what §9 promised: an indexed read of persisted rows.

## 10. UI / UX architecture

Nine screens + one widget family in V1. **As-built decisions (#32, #40):**
navigation is a **4-tab `TabView`** — Overdue, Upcoming, Contacts, Settings —
each tab owning its own `NavigationStack` with per-tab `NavigationPath`, so a
push inside Overdue never bleeds into Upcoming and tab state survives
switching. On iOS 18+, Contacts is the system search-role destination and the
tab style adapts to an iPad sidebar; iOS 17 retains the four-item tab bar.
On iOS 26, the tab bar minimizes while scrolling. v0.5's “one Home screen with
a segmented control” is superseded; the segmented Overdue/Upcoming pill at the
top of both list screens **stays** as a glanceable count + one-tap cross-switch
(it displays live counts, which the tab bar can't). Its selected state uses
Liquid Glass only on iOS 26; the surface treatment remains on earlier systems.
Contact rows use matched zoom navigation on iOS 18+, disabled when Reduce
Motion is enabled. `ContactDetailScreen` is constructed by a factory
(`contactDetail(for:)`) so each push gets a fresh VM — never rely on SwiftUI
view identity to reset it (regression-tested). Contact Preview is the narrow
exception: its concrete-contact item destination is child-local state inside
the same tab `NavigationStack`; the tab path continues to own the Contact
Detail push, and the standard Back action clears the child item before
returning through that path.

1. **Overdue (Home)** — overdue contacts sectioned by priority tier. Row: photo, name, "2 weeks overdue", channel icon (tap = open deep link), merged-group chip where applicable. Swipe: **Caught up** / **Snooze 1 wk** (shipped as per-row buttons, R52). Footer shows the live next-digest time (from persisted reminders — the shipped hardcoded "6:00 pm" strings are R11). Empty state: "All caught up."
2. **Upcoming** — reminders in the next `digestHorizonDays` (7/14/30, user-set), grouped by day, from **persisted** `ScheduledReminder` rows via `ValueObservation` (R10). Rows show contact, channel, kind tag (birthday/anniversary), scheduled time. Swipe: **Reach out now** (opens deep link + logs interaction + advances cadence) / **Mark caught up** (the latter shipped as a per-row button, R52). The former inert nav-bar Horizon control is removed; the real horizon editor lands with persisted Reminder Windows in TF-05.
3. **All Contacts** — every active local contact, including untracked rows from
   the first import so a fresh production launch is immediately useful; system
   search-role destination on iOS 18+ with `.searchable` scoped to this screen,
   native `ContentUnavailableView` search/empty states, sections by priority
   tier, group-membership indicator, tap → Contact Detail. TF-03 adds the
   tracked/all filter alongside reconciliation so users can narrow the list
   without hiding a first import by default.
4. **Contact Detail** — hero (photo/name/priority), cadence card (cadence, **live** next reminder, last interaction, status), channel card with **working "Open [channel]"** button, actions: **Caught up** (logs + reschedules), **Snooze 1 wk**, **Log other channel…**; interactions list (last 8); Regards-local notes with "private to Regards" footnote; **Edit contact** (→ screen 5); reminder-window override editor entry; "Merged with…" disclosure when grouped (→ screen 6 context).
5. **Edit Contact** — real form (`TextField`s) mirroring system-contact fields: name, phones, emails, postal addresses, birthday, anniversary. Save = partial-field `CNSaveRequest` write-back of touched fields only; Cancel/back always available. The interim screen now has a standard Back escape route and no inert Save/Cancel controls; the real form lands in TF-09 (PR27). Regards-local `notes` visible but labeled not-written-back. Write-permission-denied state links to Settings.
6. **Merge Duplicates** (Settings entry) — ranked candidate pairs (§7 heuristic) with side-by-side preview; user picks the primary face; **Confirm creates a `ContactGroup` row** (shipped gap R12: nothing persists); one-tap Undo (delete group); **Skip** dismisses a pair persistently (store dismissed pair hashes locally); manual "link two contacts…" flow for heuristic misses.
7. **Settings** — Reminder windows (→ screen 9), quiet hours, occasion notification time, Upcoming horizon, digest preview, Find duplicate contacts, notification permission status + re-prompt, entitlement card (trial countdown / unlock / restore purchases / tip jar, Phase 2), **Export my data** (JSON to Files), **Delete everything** (wipe DB + reset first-run), Transparency screen, "Behind the App" (journal link — the app's one outbound *user-initiated* Safari link; it does not violate §11 because it's `openURL` to the system browser, no in-app networking), Contact support (mailto with prefilled diagnostics), Onboarding replay.
8. **Onboarding** — 3 screens: (a) concept sell ("who have you been meaning to call?"), (b) Contacts permission pre-prompt → system prompt, (c) optional Calendar pre-prompt + pick-your-first-3-contacts starter (search, set cadence+channel inline). Gated by `UserProfile.onboardingCompletedAt` in the launch path. TF-02 supplies the Contacts pre-prompt, retry, and browse-only path; its **Continue without contacts** choice completes onboarding and has no later Contacts re-entry. PR29 owns the Settings re-entry/deep link plus the remaining starter and notification steps (R14).
9. **Reminder Windows** (pushed from Settings; promoted to a first-class Features folder, decision #33) — **live editor**, not the shipped display-only mock (R9): day pills toggle `allowedDaysMask`, time ranges add/edit/remove with overlap validation, quiet-hours editor (wrap allowed), zero-capacity configs refuse to save with inline error, writes through `ReminderWindowRepository` and triggers `SchedulingPass.runFull()`.

Plus **Transparency** (static, shipped) under Settings — plain-language privacy proof with links out (wire the three inert "Open" rows to `openURL`, R15).

**Widget family (Phase 2, §14):** small (top-3 overdue), medium (top-5 + per-icon deep links via `widgetURL`), Lock Screen circular/inline count. Reads a **read-only GRDB connection** on a shared App Group container (`group.com.consideratesoftware.regards`); main app calls `WidgetCenter.shared.reloadAllTimelines()` after every SchedulingPass. No network, no new permissions.

**Design system:** `RegardsDS` tokens (colors incl. WCAG-checked pairs in
`RegardsPalette.contrastPairs`, typography, spacing) + primitives (`Avatar`,
`ChannelGlyph`, `Tag`, `Wordmark`, `RegardsSegmentedControl`) and
availability-gated platform-effect modifiers. Native navigation titles and
empty states replace the Phase 0 custom-nav imitation. Liquid Glass is reserved
for the selected functional control and system chrome; content cards do not
become glass. Rule: **no inert interactive-looking controls in shipped UI** —
every stub is enumerated in §19 and each Phase 1 PR must wire or remove the
stubs in the screens it touches.

**Accessibility is release-blocking and reviewed on every PR.** As of 2026-08-02 the automated audits no longer run on pull requests: the 1x audit runs on merges to `main`, while the 5x stress sweep runs nightly and on demand before a release (both use `macos-latest`; repeated real sweeps averaged 33 minutes at 10x billing, and a flake previously blocked unrelated PRs). UI pull requests require the App-authored `Regards staged review`, including `pr-accessibility`, focused tests for the affected flow, plus the manual VoiceOver smoke below. Repeated 5x local sweeps are not a routine PR gate; post-merge 1x and nightly 5x automation own broad flake detection, and `ios/scripts/audit-stress.sh` is reserved for investigating a reproduced failure or validating an explicitly requested release candidate. A release requires a green 5x sweep run via `workflow_dispatch`. `RegardsAccessibilityTests` runs `performAccessibilityAudit()` per screen; structural categories (`elementDetection`, `sufficientElementDescription`, `trait`) gate today; sensory categories (`contrast`, `hitRegion`, `dynamicType`, `textClipped`) are carved out until PR34 flips `structuralAuditCategories` → all categories (tracked in `ios/docs/accessibility.md` "Sensory-audit carve-outs"). Every screen has a row in that doc's audited table, including Edit Contact (R16). Manual VoiceOver smoke (`ios/docs/accessibility-smoke.md`) is required before any UI-touching merge. Dynamic Type through `accessibility5`, Reduce Motion respected (splash already does), 44×44pt targets.

## 11. Privacy & security — verifiable, not marketing

The claim: **"no data collected, no call-home, ever."** Stacked technical, legal, and transparency guarantees make it provable.

### Data handling inside the app

1. **Contacts access is read + scoped-write, always local.** Read: name, photo, phones, emails, postal addresses, birthday, anniversary dates, system identifier. Write: only user-edited fields via `CNSaveRequest`, never deletions/bulk/merges. **Before PR27 ships write-back, `NSContactsUsageDescription` must be updated to mention in-app editing** (R17) — informed consent; current copy is read-only.
2. **Minimum necessary fields imported.** Nothing beyond the list above.
3. **Calendar access optional, local-only, read-only.** iOS 17 key: `NSCalendarsFullAccessUsageDescription` (add with PR30; consider read-only access level if the entitlement/API surface allows — we never write). Denial/revocation never breaks the app; birthdays fall back to Contacts.
4. **All data at rest encrypted.** iOS: `NSFileProtectionCompleteUntilFirstUserAuthentication` on the DB (shipped in `DatabaseFactory.makeDatabase()`). Android: SQLCipher + Keystore.
5. **Data export / delete.** JSON export to Files; "Delete everything" wipes DB + resets first-run.
6. **Permission transparency.** Pre-prompt screens before each system prompt explaining exactly what we read and why.
7. **Contact names surface in more than one on-device channel, never off it.** Digest notification copy (§9: *"3 people are overdue: Leia, Luke, Padmé"*) and VoiceOver row-action announcements (e.g. "Marked Leia Organa caught up," §14 PR22) both speak or display a contact's name — still local rendering and system TTS, not a new data flow.

### Technical anti-call-home guarantees

**Android — nuclear tier:** no `android.permission.INTERNET` in the manifest → the kernel denies socket creation to the app's UID. Rules out any networked SDK forever. Enforced in code review + the `android-manifest-guard` CI job (`scripts/check-android-manifest.sh`), which also requires the app manifest's `tools:node="remove"` strip lines so a library-injected permission dies at manifest merge.

**iOS — strongest available:**
- No networking symbols in our modules; **CI-enforced** by privacy-grep (§5). StoreKit is OS-provided and exempt.
- ATS pinned in `ios/project.yml` (do not loosen):
  ```yaml
  NSAppTransportSecurity:
    NSAllowsArbitraryLoads: false
    NSAllowsArbitraryLoadsInWebContent: false
    NSAllowsLocalNetworking: false
  ```
- No networking background modes. No `AppTrackingTransparency` code at all (nothing to track).
- `PrivacyInfo.xcprivacy` (at `ios/Regards/PrivacyInfo.xcprivacy`): `NSPrivacyTracking=false`, zero tracking domains, zero collected data types. **Before Phase 3 submission, populate `NSPrivacyAccessedAPITypes` with required-reason entries for what we actually touch** (file-timestamp APIs via SQLite/GRDB; `UserDefaults` if Phase 2 uses it — verify the then-current category list and reason codes against Apple's documentation at submission time; R18).
- **Committed `Package.resolved`** pinning GRDB (R21): an app whose privacy story includes "audit the source" must have reproducible dependencies. Bumps are deliberate PRs (§21).

### Legal / store declarations

- **App Store nutrition label: "Data Not Collected"** across every category ("collected" = transmitted off-device; local processing of the user's own data is not collection under Apple's definition).
- **Play Store Data Safety:** "No data collected / no data shared"; on-device sensitive-data access disclosed as staying on-device.
- False declarations are rejection offenses — these must be exactly right, and they can be, because they're true.

### Transparency artifacts

1. **Source-available on GitHub** under PolyForm Noncommercial 1.0.0 — auditable by anyone; we say "source-available," never "open source" (OSI accuracy).
2. **Exodus Privacy report** per Android release.
3. **Network-capture demo** — Proxyman/Little Snitch video of a full session showing zero outbound connections beyond StoreKit; refreshed per major release (§21).
4. **Reproducible Android builds** documented in-repo.
5. **In-app Transparency screen** (shipped) restating all of this in plain language with working links (R15).
6. **Privacy Guides submission** post-launch (their license preference is OSI — make the case honestly, accept the outcome).
7. **Third-party audit** (Cure53/Trail of Bits class) as a "once revenue justifies it" stretch goal.

### What we explicitly do NOT claim

- That Apple/Google collect no OS-level telemetry about the app (outside our control).
- Any official "certification." The artifacts above make the promise *verifiable*; that's the whole claim.

## 11a. Support & feedback

All backend-free: `support@` via Cloudflare Email Routing with an in-app `mailto:` (pre-filled subject `[Regards {version} / {OS} / {device}]`, user-reviewed diagnostic body — the privacy-compatible alternative to Crashlytics); public GitHub Issues as bug tracker + roadmap board (Shipped / In Progress / Considering / Not Doing); respond to every store review in year 1. No help-desk SaaS, no in-app chat, no automated crash reporting — each would break the posture. Community channel only at ~500+ active users.

## 11b. Build-in-public journal

Documented on Substack (sdahiya.substack.com), biweekly baseline plus event posts on milestones, from before the first commit through post-launch.

**State as of 2026-07-01:** 3 posts published — #1 "Why I'm building Regards in the open" (Apr 15), #2 "The apps that came before Regards" (May 5), #3 "Designing reminders that respect your time" (May 12). Silent since. Post #4 (the audit-helper story) drafted but unpublished. Posts are canonical on Substack; `journal/` is gitignored scratch space for drafts.

**The restart calendar, drafts, and per-post outlines live in
`journal/SCHEDULE.md`** (local, not committed). Its former July–October dates
were tied to the expired launch anchor and must be rebaselined from the
internal/external TestFlight gates before publishing new commitments.

**Editorial voice:** what I'm building and why — never what others get wrong. Appreciative, factual comparisons only. Every post links the repo, the app (once live), and 1–2 prior posts. Writing follows Sid's WRITING RULES doc (hard bans: em dashes, negative-parallelism reframes, analogies, metaphor verbs, throat-clearing, rule-of-three padding; numerals for numbers). Realistic target: ~400 subscribers at month 12; conversion beats list size.

**Integration:** Settings → "Behind the App"; store listings link the journal; README header links it; landing page above the fold.

## 12. Module / package layout

### iOS — as built today + planned additions (single Xcode project via XcodeGen)

```
ios/
  project.yml                     — XcodeGen source of truth; NEVER hand-edit the xcodeproj
  Regards/
    App/                          — RegardsApp (@main), AppEnvironment (DI), typed tab/intent router,
                                    tab root, screen factories
                                    [Phase 1C adds: SchedulingPass]
    Domain/                       — pure Swift, CI-guarded (§5)
      Contact.swift, ContactGroup (in Contact.swift), ScheduledReminder.swift,
      InteractionLog.swift, UserProfile.swift, ReminderWindow.swift,
      TimeOfDay.swift, DayOfWeek.swift, Contact+Accessibility.swift
      Channels/                   — Channel.swift, ChannelCatalog.swift, DeepLinkBuilder.swift
      Reminders/                  — ReminderEngine.swift, DuplicateDetector.swift
    Data/                         — DatabaseFactory, DatabaseMigrator (v1, v2…), Records, Repositories,
                                    MockRepositories
    Platform/
      AppIntents/                 — iOS 26 local open-section App Shortcut
      Contacts/                   — ContactsSource (CNContactStore adapter), ContactsImporter
                                    [PR21 adds reconciliation; PR27 adds ContactsWriter]
      Notifications/              — [PR24] NotificationScheduling adapter (UNUserNotificationCenter)
      Calendar/                   — [PR30] CalendarSource (EventKit)
      DeepLinks/                  — [PR26] DeepLinker (UIApplication.open)
      Billing/                    — [PR32] StoreKit 2 entitlement service
    DesignSystem/                 — RegardsDS tokens, RegardsColors (+contrastPairs), Primitives/,
                                    availability-gated navigation-transition effects
    Features/
      Overdue/  Upcoming/  Contacts/  ContactDetail/  EditContact/
      MergeDuplicates/  ReminderWindows/  Onboarding/  Settings/ (incl. TransparencyScreen)
      Shared/                     — RegardsSegmentedControl etc.
      Paywall/                    — [PR32]
    Resources/                    — Info.plist (generated), Assets.xcassets
    PrivacyInfo.xcprivacy         — privacy manifest (note: lives at Regards/ root, not Resources/)
  RegardsWidget/                  — [PR31] WidgetKit extension target (App Group, read-only DB)
  RegardsTests/                   — swift-testing unit bundle (Domain, Data, Platform fakes, VMs)
  RegardsAccessibilityTests/      — XCUITest audit bundle (post-merge 1x; nightly/release 5x)
  docs/                           — accessibility.md, accessibility-smoke.md, modern-ios.md
  scripts/                        — audit-stress.sh (on-demand flake investigation / release helper)
```

Each screen folder owns `*Screen.swift` + `*ViewModel.swift` where stateful. All feature code talks to `any *Repository` protocols — never concrete GRDB types — so the mock↔production swap stays a one-line change in `RegardsApp`.

### Android (follow-on; unchanged plan)

```
:app  :feature:{overdue,upcoming,contacts,contact-detail,edit-contact,merge-duplicates,onboarding,settings,paywall}
:widget  :domain (pure Kotlin port of iOS Domain + same tests)  :data (Room+SQLCipher)
:platform:{contacts,calendar,notifications,deeplinks,billing}
```

## 13. Testing strategy

**Shipped suites (census 2026-08-09):** the unit target executes 266 tests across ReminderEngine, annual recurrence, DST, reminder-window validation, Contacts import, repositories and migrations, production launch coordination, duplicate detection, deep links, App Intent routing, feature load states, contact accessibility, color and asset hygiene, and Overdue, Upcoming, All Contacts, and Merge Duplicates ViewModel behavior. The accessibility target has 29 XCUI tests: screen audits plus navigation, layout, launch-recovery, and accessibility-contract regressions. The unused general UI-test placeholder target and its one placeholder unit test were removed in TF-01 (R22).

**Standing requirements:**

- **Domain: exhaustive unit coverage, CI-enforced floor.** The unit-tests job enforces ≥95% line coverage on `ios/Regards/Domain/**` via `xccov` (the v0.5 "100%" aspiration meets reality at 95% + mandatory tests for every listed edge case). The floor may only go up.
- **Engine edge cases that MUST have tests after PR16** (each currently missing and each guards a shipped or latent defect): a window **on** a DST transition day (US 2026 transitions Mar 8 / Nov 1 are Sundays — the shipped tests use weekday-only windows and dodge the bug; add Sunday-inclusive windows and a synthetic zone like `Australia/Lord_Howe` for the 30-min case), fall-back duplicated-hour disambiguation, spring-forward nonexistent slot-start, midnight-boundary walk, contiguous-range collapse, wrap-rejection validation, degenerate-window → nil, quiet-hours-consume-everything → nil, same-day-late occasion fires today, never-contacted anchor = createdAt, slot-start snapping equality.
- **Deep-link parametric completeness:** one case per `Channel` (a test asserts the parametric list covers `Channel.allCases`), plus the property `isValid ⟹ build != nil` for every link-bearing channel, plus the specific regressions: facetime-email, m.me URL, `@handle` telegram, non-http custom scheme.
- **SchedulingPass (PR25):** fake repos + fake `NotificationScheduling`; assert idempotence, orphan cancellation, group-collapse (one reminder per group), digest identity stability, 60-cap behavior.
- **Migrations:** fresh-create and v1→v2 upgrade round-trips for every table; migration tests may never be deleted, only added.
- **Repositories:** contract tests run against both `MockRepositories` and GRDB implementations (shared assertions) so mocks can't drift from production semantics (R23).
- **ViewModels:** every VM gets a unit suite. PR #42 added focused Upcoming
  coverage across three files: representative reminder seeds, stable row
  identity, and ordering live in `MockRepositoriesTests`; horizon, DST, and
  same-day boundaries live in `UpcomingViewModelBoundaryTests`; the states that
  leave the happy path live in `UpcomingViewModelStateTests` (a throwing
  contact fetch, a throwing `fetchAllPending`, a failure after a successful
  load, a zero-capacity window that keeps occasion rows, an untracked contact's
  occasion, the documented §9 contract-6 duplicate, and the spoken row label).
  `ContactDetailInteractionLabelTests` covers the Contact Detail interaction
  row's spoken label; the rest of ContactDetail and the remaining Upcoming
  behaviors stay open under R24.
- **Snapshot tests (PR34, decision #34):** adopt `pointfreeco/swift-snapshot-testing` (test-target-only dependency — it never enters app sources, so no privacy-grep implications) for the 9 screens × key states (empty / populated / all-caught-up / trial-expired / post-purchase). The `ios-ci.yml` snapshot placeholder comment becomes a real job.
- **StoreKit (PR32):** StoreKitTest configuration file + sandbox smoke: purchase, restore-from-fresh-install, trial expiry math.
- **Accessibility:** run the focused `RegardsAccessibilityTests` cases affected by a UI or UI-test diff. Do not require a repeated local sweep for routine PRs. In CI both broad audits live off the pull-request path (see §10): the 1x audit runs on merges to main, while the 5x sweep runs nightly and on demand before a release. Use `ios/scripts/audit-stress.sh` only to investigate a reproduced flake or an explicitly requested release candidate. Test-pattern rule (learned the hard way, PR #11/#12): don't `waitForExistence` on predicate-matched queries; plain element queries for waits, predicates for read-after-known.
- **Manual:** VoiceOver smoke per `ios/docs/accessibility-smoke.md` before
  UI-touching merges; PR21 owns the synthetic 5k-contact regression, and the
  physical A15 performance budget is confirmed at the TF-18 release gate
  (R25).

## 14. Phased roadmap — rebaselined 2026-07-01

**Execution control:** `TESTFLIGHT_PLAN.md` is the live queue and recovery
protocol. The PR labels below are stable scope aliases, not current GitHub pull
request numbers, and the 2026 dates below are historical planning anchors.
`TESTFLIGHT_PLAN.md` governs ordering and status; this section continues to
govern scope and acceptance criteria.

**History:** Phase 0 shipped on plan (PRs #1–#5, Apr 19 – May 3). Phase 1
started with GRDB wiring and Contacts plumbing, paused on 2026-05-06, and
resumed in July with the engine, accessibility, channel, namespace, and review
infrastructure work now reflected in §18. The legacy PR labels below are kept
because the remediation register cites them.

**Planning anchor:** the former 2026-08-31 launch date expired before the core
production loop existed. Do not schedule against it. `TESTFLIGHT_PLAN.md`
defines an internal-beta gate after the core loop and an external-beta gate
after V1 is feature-complete. Re-estimate a public launch from measured beta
throughput. Up to three dependency-independent implementation lanes may run in
linked worktrees under `TESTFLIGHT_PLAN.md`; true parent/child work stays in a
single stacked lane. If scope must move, cut in this order: PR35 localization
scaffolding → medium widget (ship small+lock only) → snapshot breadth (keep 4
core screens). Never cut accessibility gates, privacy invariants, or the §9
contract.

### Dedicated iOS platform modernization (owner-directed, Jul 30)

This is a standalone refactor PR stacked on TF-01 slice 1. It changes platform
composition, not product scope, persistence, notification behavior, or privacy
boundaries.

| Scope | Key acceptance criteria |
|---|---|
| Native iOS 17 baseline chrome and empty states; iOS 18 value-based tabs, search role, adaptive sidebar, and Reduce-Motion-aware zoom transitions; iOS 26 Liquid Glass control state, scroll-minimizing tab bar, and local open-section App Shortcut | Xcode 26.6 / iOS 26.5 build and metadata extraction pass; iOS 17 fallback compiles and launches; App Shortcut exposes no personal data; focused accessibility regressions, manual smoke, and staged accessibility review pass; scheduled broad audits remain green on current `main`; no iOS 27 beta API; sibling adoption matrix in `ios/docs/modern-ios.md` |

### Phase 1R — Remediation (Jul 6–10) — fix what's wrong before building on it

| PR | Scope | Key acceptance criteria |
|---|---|---|
| **PR16** | Engine contract fixes: wall-clock slot math, `Date?` return + degenerate handling, wrap/timezone rejection in `ReminderWindow` validation, never-contacted = `?? createdAt`, same-day-late occasion, eligibility-safe slot-start snapping in `batch` semantics | R1, R3–R6, R8, R47–R48 engine portions closed; all §13 engine edge-case tests green; no force-unwraps in changed paths (R26) |
| **PR17** | Channel/validation fixes: facetime email pass-through, m.me normalization, `@` stripping, custom = any-scheme URL; `isValid ⟹ build` property test for link-bearing channels; parametric covers `allCases` | R2, R7 closed |
| **PR18** | Truth pass on docs + merge the orphan: merge `origin/ios/section-header-accessibility-label` (+7 lines, likely kills the 20% audit flake); fix CLAUDE.md's 5 stale claims; README (drop `docs/DOMAIN_MODEL.md` + `android/` refs); accessibility.md (remove ghost `waitForContactDetailReady` reference, add Edit Contact row + audit test); unify simulator name (iPhone 17 Pro) across CLAUDE.md/docs/scripts | R16, R27, and R28 closed; README half of R19 closed (root link guard remains PR19); R20 was closed by GitHub PR #22; R29 was closed by PR16 plus PR20–PR22 stress runs; historical acceptance evidence passed 5/5 ×3 consecutive stress runs. Under decision #39, later UI follow-ups pass focused regressions and manual smoke before merge; scheduled runs own repeated stress. |
| **PR19** | Repo + CI hygiene, delivered as bounded TF-01 slices: commit `Package.resolved`; remove placeholder tests; check root Markdown; enforce a ≥95% Domain coverage floor; remove dead SwiftLint configuration; reconcile workflow and merge-method docs. Follow with exact-target stale-worktree cleanup, representative mock seeds, stable row IDs, and dead-asset cleanup. Guard hardening (R32) was completed by the trusted-gate prerequisite. | GitHub PR #39 merged as `ade40e3`, closing R19, R21, R22, R31, and R33. GitHub PR #42 merged as `d8193ff`, closing R34/R36 and R40. GitHub PR #43 closed the TF-01 checkpoint and XcodeGen determinism repair at `8adeb0d`. R30 remains open where exact-target verification finds unique work. |

### Phase 1B — Production wiring (Jul 13–17) — the mock era ends

| PR | Scope | Key acceptance criteria |
|---|---|---|
| **PR20** | Build the file-backed `ProductionRepositoryFactory`, compose `AppRuntime.makeProduction(environment:)` through `AppLaunchCoordinator`, migrate to `v2` (§7 columns), add the first-launch import flow and `onboardingCompletedAt` gate, and keep the splash until actual load completion | Fresh install on device: onboarding → Contacts permission → import → populated All Contacts. Imported contacts remain untracked until PR29's starter selection, so Overdue and Upcoming may be empty. Mock path stays for previews/UI tests via launch argument |
| **PR21** | Reconciliation: launch/foreground + `CNContactStoreDidChange` re-import; archive-on-delete; refresh names/handles (`phonesJson`/`emailsJson`); importer per-row fault tolerance (R35); move Contacts enumeration off the cooperative pool with a synthetic 5k regression (R25) | Re-add/rename a contact, or un-archive one back into view, in the system app → Regards reflects it next foreground. Delete one → Regards archives it after a second `.authorized` pass confirms the miss at least `archiveDebounceFloor` (5 minutes) later, and that debounce state survives a relaunch in between (§7). History survives archive; synthetic 5k import does not block the cooperative pool |
| **PR22** | The core loop: Caught up / Snooze / Log-other wired everywhere (Detail buttons, Overdue+Upcoming row actions) → `InteractionRepository.append` + `lastInteractedAt` + targeted SchedulingPass stub (DB-only until PR25); stable row identities (R36); Overdue/Upcoming subscribe once to `ContactRepository.observeTracked()` for live cross-screen updates, guarded against a double-subscribe race by a synchronous `Task {}` placeholder written to `observationTask` before the `await` that registers the real subscription | Marking caught-up moves the contact out of Overdue instantly and logs an interaction; snooze pushes 7 days; a Caught-up/Log-other write from one screen's reference is reflected on the other without leaving it, via `observeTracked()` — Contact-table writes only. A Snooze write touches only `ScheduledReminder`, which `observeTracked()` doesn't cover, so it's picked up on the next `load()`, not live; that gap closes with R10/PR25's `ScheduledReminder ⋈ Contact` observation pipeline. Two concurrent `load()` calls subscribe exactly once; VM tests |
| **PR23** | Reminder-window persistence: ReminderWindows screen becomes a live editor (days/ranges/quiet-hours/occasion-time/horizon), writes via `ReminderWindowRepository`, zero-capacity refuses save; Upcoming/Overdue read the real global window + per-contact overrides (R9) | Edited windows survive relaunch and visibly re-shape Upcoming |

### Phase 1C — Notifications end-to-end (Jul 20–24) — the product starts existing

| PR | Scope | Key acceptance criteria |
|---|---|---|
| **PR24** | `Platform/Notifications` adapter (`NotificationScheduling`), permission pre-prompt + request in onboarding step (c) and Settings, notification categories/actions (Caught up / Snooze / open) | Local notification fires on device at a window boundary; actions round-trip |
| **PR25** | `SchedulingPass` actor: full + targeted runs, digest batching (slot-start snapping, `digest-{epoch}` identity), occasion scheduling from injected/available inputs (production Contacts/EventKit activation stays PR30), no-double-up rule, orphan cancellation, launch/foreground reconcile; Upcoming switches to `ValueObservation` over persisted rows (R10); live digest labels (R11) | Idempotence + reconcile tests green; airplane-mode device test: overdue contact → digest at next window open |
| **PR26** | Deep-link execution: `DeepLinker` adapter, channel taps wired in all 4 surfaces, notification tap-through routing (digest → Overdue; single → Contact Detail), `LSApplicationQueriesSchemes: [discord]`, `reminder_tap` interaction logging | Tapping WhatsApp row on device opens WhatsApp to the contact; R37 closed |

### Phase 1D — Editing, merging, onboarding, calendar (Jul 27–31)

| PR | Scope | Key acceptance criteria |
|---|---|---|
| **PR27** | Edit Contact: real form, dirty-field tracking, partial `CNSaveRequest` write-back via `ContactsWriter`, re-fetch after save, nav trap fixed (R13), write-denied state, `NSContactsUsageDescription` reworded (R17) | Edit phone on device → visible in system Contacts app; only touched fields written; audit test added |
| **PR28** | Merge for real: confirm→`ContactGroup` write, group-aware SchedulingPass (one reminder/group, member-max interaction), one-row-per-group in Overdue/Upcoming, unmerge, persistent skip, manual link, detector fed full handle sets (R12) | Two "Mom" entries → one reminder; unmerge restores; group chip reachable and audited |
| **PR29** | Onboarding: 3-screen flow in launch path (R14), pre-prompts, first-3-contacts starter, denial paths | Fresh-install TestFlight-ready first-run |
| **PR30** | Calendar birthdays: `CalendarSource` (EventKit), `NSCalendarsFullAccessUsageDescription`, Settings toggle, re-add `CNContactBirthdayKey` to `CNContactsSource`, populate `SystemContact.birthday`, update the Contacts pre-prompt before that read begins, add the `CNContactImageDataKey` fetch and wire `photoRef` refresh into `ContactsReconciler` (deferred from PR21, §7), and merge non-persisted Contacts/EventKit occasion inputs with Contacts winning | Calendar-only birthday appears in Upcoming; revoking permission degrades gracefully; a changed system photo refreshes `photoRef` on the next reconcile pass |

### Phase 2 — Widget, monetization, polish (Aug 3–14)

| PR | Scope | Key acceptance criteria |
|---|---|---|
| **PR31** | Widget target: `RegardsWidget` in project.yml, App Group (`group.com.consideratesoftware.regards`), DB relocation to group container (+ migration of existing store), read-only widget queries, small/medium/lock variants, `reloadAllTimelines()` after SchedulingPass | Widgets live on device; app-group migration preserves data across update |
| **PR32** | StoreKit 2: entitlement service (`Platform/Billing`), trial state machine (`trialStartedAt`), Paywall screen, soft-lock on expiry (read-only + banner, never data loss), tip jar, Restore, StoreKitTest suite | Sandbox purchase/restore/expiry all pass; zero StoreKit imports outside `Platform/Billing` + Paywall |
| **PR33** | Settings completion: export JSON, delete-everything (+ confirmation), support mailto with diagnostics, Behind-the-App link, entitlement card | Export produces valid JSON of all 6 tables; delete returns to onboarding |
| **PR34** | Accessibility + visual hardening: fix sensory findings (ScaledMetric on fixed-size glyphs, contrast leftovers, hit regions), flip audit to **all** categories, snapshot tests (9 screens × states) + CI job, Dynamic Type pass to accessibility5 | Full-category audit green ×5 stress runs; snapshot job gating |
| **PR35** | Localization scaffolding (String Catalog, en at launch), final copy pass, and launch polish before accessibility and snapshot baselines freeze | String Catalog covers user-facing copy; launch surfaces contain no placeholder or clipped text |

### Phase 3 — Submission & launch (gate-based; legacy Aug 17–31 window retired)

- **Internal gate:** build 1.0.0 after `TESTFLIGHT_PLAN.md`'s `TF-08` and
  `TF-11`; run the
  first §20 verification pass and collect core-loop feedback.
- **External gate:** finish `TF-09`–`TF-18`, submit the feature-complete build
  for beta review, recruit 10–20 testers, and merge only P0/P1 fixes during the
  freeze.
- **Submission candidate:** run the full §20 checklist again, including
  listing metadata, nutrition label, PrivacyInfo required-reason entries,
  screenshots, and review notes.
- **Review and release:** submit with manual release. Choose the public date
  only after approval and beta exit criteria; publish launch material on that
  date.

### V1.1 — Holiday Pack (Sep 1 – Oct 6)

CSV/XLSX holiday-card export matched to Shutterfly/Minted/Zola/Paper Culture
address-import schemas; address-editing UI on the PR27 write-back rails;
per-contact "gets a card" flag independent of tracking. Re-estimate after V1
stabilizes in external TestFlight.

### Android track (Q4 2026, after iOS stabilizes)

Port order and estimates unchanged from v0.5 (~6 weeks: domain port driven by the Swift test suite → Compose shell → integrations → Play submission with the no-INTERNET manifest as the marquee artifact). Start gate: iOS crash-free ≥99.5% over 2 weeks and support volume < 30 min/day.

### V2 candidates (unchanged, still explicitly not V1)

Talking points / conversation queue (the surface-at-reminder-time twist stays the differentiator); email metadata integration; TDLib; share-sheet logging; device-sync via iCloud/Drive; streaks; ICS import; top-5 localization; watch/Wear companions.

## 15. Open questions

1. **Android exact-alarm permission** — measure denial in Android beta (unchanged).
2. **Discord user IDs** — V1 opens Discord generically without an ID; acceptable? Revisit with user feedback.
3. **Contacts WRITE acceptance** — iOS asks read+write in one prompt; if TestFlight shows denial spikes, split the ask (read at onboarding, write on first edit).
4. **Duplicate-heuristic tuning** — local-only accept/dismiss counters exist per §7; review after 4 weeks of real use.
5. **Widget refresh cadence** — `reloadAllTimelines()` after each SchedulingPass should suffice; verify WidgetKit budget behavior in TestFlight.
6. **Geo-tier drift** — quarterly pricing review year 1 (§21).
7. **Xcode 26 / iOS 26 timing** — decide the submission toolchain at Phase 3
   entry and smoke-test on the current GM before release (§21).
8. ~~Android launch timing~~ → resolved into the Q4 start gate above.

## 16. Decisions log

Decisions #1–#22 (2026-04-15 → 2026-04-19) are unchanged from v0.5 and remain binding; #23+ added at the v1.0 rebaseline.

| # | Decision | Date | Rationale |
|---|---|---|---|
| 1 | V1 ships with NO passive messaging integrations | 2026-04-15 | Ship the core reminder UX first; integrations are risky and can wait. |
| 2 | Native on both platforms, no KMP | 2026-04-15 | Shared logic is small; platform APIs are the interesting part. |
| 3 | Local-first, no backend | 2026-04-15 | Trust is the moat. Contacts + cadence is too personal for a server. |
| 4 | Reminder-window gating is first-class | 2026-04-15 | Unique positioning vs. Dex/Covve/Smart Contact Reminder. |
| 5 | Universal HTTPS deep links preferred over custom schemes | 2026-04-15 | Graceful web fallback; fewer Info.plist declarations. |
| 6 | Batched digest notification, not per-contact | 2026-04-15 | Per-contact nags get the app silenced. |
| 7 | One-time $4.99 + tip jar, no subscriptions, no ads ever | 2026-04-15 | Local-only app; subscription would be dishonest. |
| 8 | No free tier with contact caps; 7-day trial instead | 2026-04-15 | Caps feel punitive; trust the user with the full app. |
| 9 | Android: no `INTERNET` permission; iOS: strict ATS defaults with every exception disabled + no networking code | 2026-04-15 | Kernel-enforced guarantee on Android; source guards are the verifiable iOS enforcement because ATS is not a kernel-level denial. |
| 10 | Source-available under PolyForm Noncommercial 1.0.0 | 2026-04-15 | ~95% of the credibility of MIT/Apache with protection against commercial cloning. |
| 11 | Support via mailto:, GitHub Issues, manual diagnostics | 2026-04-15 | Backend-free; preserves zero-data-collection. |
| 12 | Named the app **Regards** | 2026-04-15 | Clarity, warmth, searchability; shortlist rejections documented in v0.5. |
| 13 | Build documented publicly on Substack, biweekly | 2026-04-15 | Acquisition channel + transparency artifact + design log. |
| 14 | Birthday & anniversary reminders in V1 | 2026-04-15 | Table stakes; modest scope on top of ScheduledReminder. |
| 15 | Calendar via local EventKit/CalendarContract only; OAuth calendar permanently out | 2026-04-15 | OAuth would collapse the verifiable-privacy guarantee. |
| 16 | Holiday card export = V1.1 (September), not V1 | 2026-04-15 | Single-season utility; better as a focused drop. |
| 17 | V1 includes contact editing with system write-back | 2026-04-15 | Needed for Holiday Pack; quality-of-life win; on-device writes keep the posture. |
| 18 | V1 includes virtual-merge duplicate detection; system contacts never modified | 2026-04-15 | Messy address books double-remind without it. |
| 19 | V1 includes widgets | 2026-04-15 | Small scope, no new permissions, retention win. |
| 20 | iOS first; Android after iOS public launch | 2026-04-15 | Apple review latency first; Swift domain becomes the port reference. |
| 21 | Geo-tiered pricing anchored $4.99 → $0.99 | 2026-04-15 | PPP tiers expand the market at zero operational cost. |
| 22 | Talking points / conversation queue deferred to V2 | 2026-04-19 | Additive to the core loop; the reminder-time surfacing twist is preserved for V2. |
| 23 | Entitlement tiers are exactly `free \| trial \| lifetime` | 2026-07-01 | §7 in v0.5 still carried subscription-era tiers; code was right since PR #2. Doc aligned to code + decision #7. |
| 24 | `DOMAIN_MODEL.md` will not exist | 2026-07-01 | The Swift domain layer + test suite is the executable spec for the Android port; a third artifact would drift. |
| 25 | Phone duplicate-matching uses the last-10-digit key, not strict E.164 | 2026-07-01 | Matches formatting/prefix variance without a parsing dependency; false-positive window within one address book is negligible. |
| 26 | Duplicate confidence: phone=high, email=medium, name-only=low | 2026-07-01 | Shared family emails make email weaker than a shared line. Resolves the shipped docstring/behavior mismatch in favor of behavior. |
| 27 | Channel validation contract: `isValid(v) ⟹ build(v) != nil`, property-tested per link-bearing channel; `in_person` is the explicit no-link exception | 2026-07-01 | Validation and building drifted independently (FaceTime email bug). One invariant kills the class without misrepresenting the no-link channel. |
| 28 | Allowed time ranges must not wrap midnight; quiet hours may | 2026-07-01 | The walk can't honor wrapping allowed ranges and the editor never offers them; make the state unrepresentable. |
| 29 | Never-contacted cadence anchor = `createdAt` | 2026-07-01 | "Instantly overdue on import" floods first-run Overdue and teaches users to ignore it. Engine aligned to the ViewModels. |
| 30 | Reminders snap to window-slot start; digest identity = `digest-{slotStartEpoch}` | 2026-07-01 | Makes batching exact-equality by construction and OS-notification dedup trivial. |
| 31 | Snooze moves `scheduledFor` only; `lastInteractedAt` untouched, no InteractionLog row | 2026-07-01 | Snoozing is not talking to someone; cadence math must not think it is. |
| 32 | Navigation is a 4-tab TabView; the Overdue/Upcoming count pill stays | 2026-07-01 | As built and shipped through audit; the pill carries live counts the tab bar can't. Supersedes v0.5's single-Home segmented design. |
| 33 | Reminder Windows is a first-class screen (`Features/ReminderWindows/`), pushed from Settings | 2026-07-01 | The editor is too rich for a Settings subsection; §12 updated to match reality. |
| 34 | Snapshot testing via pointfree swift-snapshot-testing, test targets only | 2026-07-01 | Fills the §13 commitment; test-only dependency, no privacy-grep surface. |
| 35 | Version bumps 0.1.0 → 1.0.0 at the first TestFlight feature freeze; fixed-date timing superseded by #38 | 2026-07-01 | The version rule survives; the former Aug 14 / Aug 31 anchors do not. |
| 36 | `SchedulingPass` actor is the sole writer of ScheduledReminder rows and OS notifications | 2026-07-01 | One idempotent choke point; UI is read-only over persisted reminders. |
| 37 | `Package.resolved` is committed | 2026-07-01 | Reproducible builds are part of the privacy claim; floating deps contradict it. |
| 38 | TestFlight execution uses stable `TF-##` IDs and readiness gates, not a fixed public date | 2026-07-29 | The 2026-08-31 anchor expired before the production loop existed. Durable Git/GitHub checkpoints survive agent context and capacity resets; beta throughput determines the public date. |
| 39 | The single accessibility audit runs after merge; the five-run sweep runs nightly and by manual dispatch before release; pull requests use focused regressions, manual smoke, and staged accessibility review | 2026-08-03 | The former PR-time single and five-run jobs each occupied a billed macOS runner for about 33 minutes and unrelated flakes blocked feature throughput. Scheduled runs preserve broad detection; a failed current-main run must be triaged before new feature work, while `audit-stress.sh` remains available for reproduced flakes and release candidates. |
| 40 | Showcase the latest shippable iOS platform in one dedicated compatibility-gated refactor; keep iOS 17 minimum and exclude beta-only APIs | 2026-07-30 | Xcode 26.6 / iOS 26 is the stable TestFlight baseline. iOS 18 and iOS 26 enhancements can be additive without abandoning supported users; iOS 27 beta APIs would make the release branch and CI unstable. |
| 41 | Android scaffold carve-out: `ANDROID_PORT.md`, the `android/` module skeleton, the Android CI guards, and the shared golden-vector infrastructure (AN-00–AN-02) may land ahead of the §21 iOS-health gate; Kotlin domain porting and all Android feature work stay gated | 2026-08-03 | The gate protects iOS focus, not groundwork. Landing architecture and guards first keeps the no-INTERNET invariant enforced from the first Android commit, and the golden vectors pay iOS back immediately with the transition-day engine coverage §18 found missing. `ANDROID_PORT.md` owns the `AN-##` queue; promotion past the gate line is a recorded owner edit, not an agent call. |

## 17. Working rules for implementation agents

**Reading order for any new session:** §18 → §19 → §14 (find your PR) → the spec sections your PR touches → this section. If your task contradicts this doc, stop and say so — either the task is wrong or this doc needs a sibling change in the same PR.

**The sibling-PR rule (inherited from CLAUDE.md, still absolute):** when code and this document disagree, one of them is wrong; fixing code without updating the doc (or vice versa) is an incomplete PR. Every feature PR cites the §s it implements.

**Definition of done for every PR:**
1. `cd ios && xcodegen generate` — commit `project.yml` *and* the regenerated xcodeproj (CI diffs them).
2. `swiftlint --strict` clean.
3. Full test action green locally: `xcodebuild -project Regards.xcodeproj -scheme Regards -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -onlyUsePackageVersionsFromResolvedFile test`.
4. UI/test-code touched → focused affected accessibility regressions green; repeated stress is owned by nightly/pre-release automation unless investigating a reproduced flake or validating a release candidate.
5. New/changed screens → accessibility audit test + row in `ios/docs/accessibility.md` + VoiceOver smoke.
6. §14 acceptance criteria for the PR demonstrably met (device test where the criteria say "on device").
7. Doc siblings updated (this file, CLAUDE.md if commands/paths changed, accessibility.md).
8. No new warnings (they're errors anyway), no force-unwraps in Domain, no `@unchecked Sendable` without a written justification comment.

**Hard prohibitions (unchanged, CI-enforced where possible):**
- Hand-editing `Regards.xcodeproj`.
- Apple-framework imports in `Domain/`.
- Any networking primitive anywhere in app sources — even wrapped — without amending §11 *first* (which should never happen; treat a failing privacy-grep as "revert my approach", not "adjust the guard").
- Loosening ATS keys, adding background modes, adding analytics/crash SDKs (they all require network anyway).
- Writing to system Contacts outside the partial-field `CNSaveRequest` pattern; deleting/merging system contacts under any circumstances.
- OAuth calendar anything.
- Renumbering §1–§17 of this document.

**Commit/PR conventions:** prefix `ios:` / `ci:` / `docs:` / `chore:`; PR description cites doc sections (e.g. "Implements §9a per PR25 scope"); deviations flagged in a "Deviations" section of the PR body. Branch names: `ios/<topic>`, `ci/<topic>`, `docs/<topic>`.

**Working with the guards:** the shared privacy script matches networking call sites, including `NSURLConnection` and `CFSocket*`, so user-facing copy may still name those symbols as bare tokens. The shared Domain script rejects plain, preconcurrency, and selective imports from every prohibited module. R32 records the fixture-backed GitHub PR #26 closure.

**When tests flake:** one flake across ~30 runs is noise — note it, don't "harden" (see journal post #5 for the scar). Reproduce ≥2/5 stress runs before writing a fix; prefer deleting cleverness over adding waits.

## 18. Current state — ground truth as of 2026-08-09

TF-02 merged through GitHub PR #44 as `b10f9ac`. The engine contract,
section-header accessibility fix, sample-data refresh, channel-validation
contract, bundle-namespace migration, durable TestFlight queue, and
cross-provider review parity guard have landed. The trusted staged reviewer now
uses a dedicated GitHub App check, shared source-boundary guards, and
check-output delivery. A single accessibility audit runs after merges; the 5×
stress suite runs nightly and by manual dispatch before release. Post-TF-02
iOS CI run `31334462438` passed determinism, build, unit tests, and coverage at
exact `main` = `b10f9ac`, then one of its 29 accessibility tests failed after
XCTest synthesized a launch-retry tap without reaching the destination. Its
exact failed-job rerun passed that original test and failed only after an iOS
**Ready for Apple Intelligence** notification overlaid the simulator; its
xcresult screenshot proves Apple classified system-banner text, not Regards
UI, as potentially inaccessible. Manually dispatched exact-main 5× stress run
`31334531081` passed all five complete suites. Neither isolated failure meets
§17's ≥2/5 repair threshold, so no masking source hardening was retained. A
diagnosed failed-job rerun then passed all 29 accessibility tests on the same
exact head. `TESTFLIGHT_PLAN.md` marks TF-02 done and exposes TF-03 plus TF-04
as independent ready lanes.
PR #41 belongs to the separate Android track and does not advance or block TF.
`TESTFLIGHT_PLAN.md` records the live pull-request state and next executable
work.

### What exists and works

- **Domain layer, pure and tested:** all §7 entities; `ReminderEngine` (cadence walk, quiet hours, annual recurrence + Feb-29, batching helper); `DuplicateDetector`; `ChannelCatalog` + `DeepLinkBuilder` for all 13 channels; `MonthDay` with round-trip validation.
- **Production data layer:** file-backed GRDB `v1` + `v2` migrations, records,
  6 repository implementations, and `DatabaseFactory` with protected
  production storage plus in-memory tests. Actor-backed `MockRepositories`
  remain explicit preview and DEBUG/UI-test fixtures.
- **9-screen SwiftUI shell** on the production runtime with real `@MainActor
  @Observable` VMs for Overdue/Upcoming/ContactDetail/MergeDuplicates; per-tab
  `NavigationStack`; fresh-VM-per-push factory (regression-tested); design
  system with WCAG-verified palette pairs.
- **Modern platform composition landed in GitHub PR #24:** native navigation/empty-state semantics on
  the iOS 17 baseline; iOS 18 value-based adaptive/search tabs and
  Reduce-Motion-aware matched navigation; iOS 26 restrained Liquid Glass,
  scroll-aware tab chrome, and a local open-section App Shortcut. The exact
  adoption and fallback matrix lives in `ios/docs/modern-ios.md`.
- **Accessibility harness:** 29 XCUI audit, navigation, layout, launch-recovery, and accessibility-contract tests, audit-stress tooling (script + workflow), documented test patterns, and a smoke script. The hosted accessibility reviewer and manual smoke gate UI pull requests; the 1x audit runs after merge, and the 5x sweep runs nightly and before release.
- **CI:** pull requests require xcodegen determinism, build, unit tests with coverage, strict SwiftLint, project syntax, shared privacy and Domain-purity guards, Markdown links, review-agent parity, and the App-authored `Regards staged review`, which is pinned in branch protection to the dedicated App's identity (app id `4461672`) so a same-repository Actions job cannot forge it. That check asserts a valid review ran for the current head, not that the reviewer approved: a missing, malformed or stale-head artifact fails it, while a `REQUEST_CHANGES` verdict publishes its blockers in the check output and passes, leaving the call to the author. The 1x accessibility audit runs after merges to `main`; the 5x sweep runs nightly and on demand before release.
- **Privacy posture in place:** ATS pinned, empty `LSApplicationQueriesSchemes`, `PrivacyInfo.xcprivacy` (tracking=false, nothing collected), read-only Contacts usage string, zero networking call sites (verified with CI's own pattern).

### What TF-02 activates (Phase 1B production foundation)

- `@main` now opens the file-backed GRDB database, runs the append-only `v2`
  migration, builds `AppRuntime.makeProduction`, and gates the tab root on the
  persisted profile. Debug previews and deterministic UI tests keep an
  explicit `--regards-mock-runtime` launch argument; Release has no mock
  fallback.
- A fresh profile starts its trial timestamp once, shows the Contacts
  pre-prompt, imports the authorized or limited system-visible set additively,
  and records `onboardingCompletedAt` only after the pass succeeds. Relaunch
  resumes an interrupted pass by skipping existing `systemContactRef` values.
  Denied/restricted access has a functional browse-without-importing path, and
  database/import failures remain visible and retryable. The current import
  persists only system identifiers, names, phone numbers, and email addresses.
  It does not request birthdays. PR30 re-adds `CNContactBirthdayKey` and maps
  `CNContact.birthday` into `SystemContact.birthday` when production occasion
  scheduling consumes it.
- The `v2` migration preserves the shipped `v1` registration and adds contact
  phone/email arrays, persisted reminder occasion time and digest horizon, and
  the profile trial timestamp. `AppRuntime` decodes the global window, but no
  production scheduling path consumes `occasionTime` yet. Its v1→v2 test
  carries representative data through all six tables, preserves a pre-v2
  per-contact override and non-null quiet-hours object, and normalizes legacy
  JSON `null` quiet hours to SQL NULL. A file-backed production-path regression
  covers protected-directory creation, migration, persistence, and reopen.
- Shared repository contracts now run against both mock and GRDB backends,
  including persistence values, ordering, validation, referential failures,
  duplicate identifiers, and timestamp normalization.
- Of 6 injected repositories the UI/runtime reads **5** (`contacts`,
  `interactions.fetchRecent`, `reminders.fetchAllPending`, `window`, and
  `profile`). The bounded
  Phase 0 mock path seeds pending birthday and anniversary reminders so those
  states remain visible and auditable; no production scheduling pass or
  reactive observation exists until TF-07. `groups` still has no direct UI
  consumer. `InteractionRepository.append` is now called from Contact
  Detail, Overdue, and Upcoming's Caught up / Log other actions (TF-04); a
  narrow `SchedulingPass` DB-only stub writes a single cadence
  `ScheduledReminder` row on Snooze, with no window/engine resolution,
  reconciliation, or batching. No notification is scheduled and no deep link
  is opened.

### What is broken (fix before building — full detail in §19)

Headline open P0s: Edit Contact is still a read-only stub; Reminder Windows is
display-only; Upcoming has no production scheduling or reactive-observation
pipeline; merge and onboarding flows do not persist.

### What does not exist at all

`SchedulingPass`'s `runFull()`/general `run(for contactId:)` reconciliation
(§9a) — only its narrow Snooze stub exists (TF-04) — notifications, deep-link
execution, reconciliation/re-import, write-back, merge persistence, the full
three-screen starter-contact and notification onboarding flow, calendar
ingestion, window editing, widgets, StoreKit/paywall enforcement,
export/delete, snapshot tests, App Store listing metadata (name/bundle/SKU
reserved 2026-04-15: `Regards: Stay in Touch`,
`com.consideratesoftware.regards`, `regards-ios` — fields empty otherwise).

## 19. Remediation register

Every known defect, drift, or stale artifact in the repo as of 2026-07-01, numbered for cross-reference (R1…), with owner PR from §14. **P0** = wrong behavior in shipped code paths or falsified promises; **P1** = spec/doc integrity; **P2** = hygiene/hardening. An R-item is closed only when its acceptance check passes and the closing PR references it.

### P0 — behavior

| R | Defect | Where | Fix / acceptance | PR |
|---|---|---|---|---|
| R1 | **DST wall-clock bug.** Slot times built as `startOfDay + minutes` (elapsed, not wall-clock); on spring-forward a 07:00–08:00 window yields 08:00 (outside window), on fall-back 06:00 (before it). Doc comment falsely claims `Calendar.nextDate` is used. Shipped tests dodge it (2026 US transitions are Sundays; test windows are weekday-only) | `ReminderEngine.swift:141-143, 202-206` | Wall-clock materialization + post-validation per §9 contract 1; transition-day tests incl. Lord Howe 30-min zone | ✅ **closed by PR16** |
| R2 | **FaceTime-by-email broken.** Email passes validation, then gets phone-normalized into a mangled `facetime:` URL | `DeepLinkBuilder.swift:12-21`; missing param case `DeepLinkBuilderTests.swift:19` | Pass emails through verbatim; property test §8 (decision #27) | ✅ **closed by PR17** |
| R3 | **Wrapping allowed ranges silently skipped** (`range.end <= timeOfDay` treats 22:00→01:00 as past) while `TimeRange` documents wrap support | `ReminderEngine.swift:182`, `TimeOfDay.swift:30-32` | Decision #28: reject wrap in allowed ranges at validation; quiet hours stay wrap-aware; tests | ✅ **closed by PR16** |
| R4 | **Degenerate window schedules at a disallowed instant** (returns input date; comment says "caller should surface a UX error"; no caller checks; a test codifies the bad behavior) | `ReminderEngine.swift:150-154, 210-212`; `ReminderEngineTests.swift:168-183` | `nextAllowedSlot → Date?`; editor refuses zero-capacity saves; SchedulingPass skips+badges on nil; rewrite the codifying test | engine semantics ✅ **closed by PR16**; editor PR23; SchedulingPass PR25 |
| R5 | **Same-day-late occasion jumps a year.** Install at noon on the birthday → no birthday nudge until next year | `ReminderEngine.swift:244-248` | §9 contract 4: fire at next possible moment today; test | engine recurrence ✅ **closed by PR16**; quiet-hours application PR25 |
| R6 | **Batching groups by exact Date equality**; reminders in the same window minutes apart never batch | `ReminderEngine.swift:271-275` | Decision #30 slot-start snapping; digest identity `digest-{slotStartEpoch}`; tests | ✅ **semantics closed by PR16** / PR25 (plumbing) |
| R7 | **Channel validation contradicts §8:** telegram `@handle` rejected; messenger m.me URLs rejected; `custom` limited to http(s) killing `slack://` etc. | `ChannelCatalog.swift:48-55, 91-93, 133-138` | Normalize/strip per §8 table; any-scheme custom URLs; parametric + property tests | ✅ **closed by PR17** |
| R8 | **Never-contacted semantics diverge:** engine says due-now; VMs say `?? createdAt` — same contact "not overdue" on screen, "scheduled" by engine | `ReminderEngine.swift:126-129` vs `OverdueViewModel.swift:82`, `UpcomingViewModel.swift:124` | Decision #29: engine adopts `?? createdAt`; divergence test | ✅ **closed by PR16** |
| R9a | **Global window injection.** `UpcomingViewModel` has no silent default; production launch opens GRDB and `AppRuntime.makeProduction` resolves the persisted singleton before tabs appear. Missing or invalid storage produces a visible retry state, never a mock fallback | `UpcomingViewModel.swift`, `AppEnvironment.swift`, `AppLaunchCoordinator.swift` | Production launch uses the stored global window; mock launch is explicit and DEBUG-only | ✅ **closed by GitHub PR #42 and TF-02 / GitHub PR #44** |
| R9b | **Per-contact override and live refresh — OPEN.** Overrides are still unresolved anywhere in the UI, a stored-window change does not refresh an open Upcoming, and the ReminderWindows screen renders `defaultV1()` display-only with a `.constant` Toggle | `ReminderWindowsScreen.swift:7,226`, `UpcomingViewModel.swift` | Live editor + repository read/write + override resolution in SchedulingPass (§9) | TF-05 (PR23) |
| R10 | **Upcoming re-derives on the fly** instead of reading persisted reminders reactively (§9 promised an indexed read + stream) | `UpcomingViewModel.swift:118-146` | `ValueObservation` over `ScheduledReminder ⋈ Contact` | PR25 |
| R11 | **Placeholder strings/stubs shipping in real screens:** hardcoded "Today, 6:30 pm" next-reminder; "next digest at 6:00 pm"; Contact Detail's Caught up/Snooze/Log-other and channel action plus Overdue channel actions are muted, unavailable content pending TF-04/TF-08; inert Merge "Skip" | `ContactDetailScreen.swift`, `OverdueViewModel.swift:29`, `UpcomingScreen.swift:26`, `OverdueScreen.swift`, `MergeDuplicatesScreen.swift:108-112` | Each stub wired or removed by the PR owning its screen; **zero inert interactive controls at Phase 2 exit** (§10 rule) | Horizon/All stubs removed ✅ **closed by TF-01 modernization / GitHub PR #24**; Caught up/Snooze/Log-other ✅ **closed by TF-04 / PR22** (Snooze via `SchedulingPass`'s DB-only stub, R52); remaining: channel action (TF-08), Merge "Skip" (PR28), and — correcting an omission from this row's own closure note (staged review round 8) — both the hardcoded "Today, 6:30 pm" next-reminder (folded into R56 alongside the related `overdueSummary` gap rather than tracked twice) and `OverdueViewModel.nextDigestLabel`'s hardcoded "next digest at 6:00 pm" (`OverdueViewModel.swift:29`, still an unset `private(set)` default with no writer — TF-07/PR25, same owner as the rest of `SchedulingPass`'s live-read surface) |
| R12 | **Merge never persists** (no `ContactGroup` written; `env.groups` unused) and detector sees only `preferredChannelValue` instead of full handle sets | `MergeDuplicatesViewModel.swift:44-55` | PR28 scope + `phonesJson`/`emailsJson` inputs | PR28 |
| R13 | **Edit Contact shipped as a navigation trap and remains a read-only stub:** the hidden Back button and mixed navigation APIs made Edit unreachable or inescapable; the interim screen now removes inert form actions | `EditContactScreen.swift`, `ContactDetailScreen.swift` | Never-hidden escape route; real form lands in PR27; audit test added (see R16) | escape route ✅ **closed by TF-01 slice 1**; real form PR27 |
| R14 | **Full onboarding remains incomplete.** TF-02 adds the persisted launch gate, Contacts pre-prompt, resumable first import, denial/retry paths, and non-inert proof link. Imported contacts deliberately remain untracked, so a fresh import populates All Contacts while Overdue and Upcoming may remain empty. Starter-contact selection (including marking the chosen contacts tracked), the notification step, and Contacts re-entry after **Continue without contacts** remain absent | `OnboardingScreen.swift`, `RegardsApp.swift`, `AppLaunchCoordinator.swift` | Complete the 3-screen starter-contact and notification flow, including tracking the selected starters and Settings re-entry for Contacts, per §10.8 | PR29 |
| R15 | **Transparency screen's 3 "Open" links inert**; repo URL hardcoded — verify before launch | `TransparencyScreen.swift:123, 183-187` | Wire `openURL`; confirm `github.com/consideratesoftware/RegardsMobileApp` is the public repo URL | PR33 |
| R49 | **Upcoming drops already-overdue contacts during an active reminder slot.** `ReminderEngine` intentionally returns the slot start for deterministic batching, but the ViewModel rejects it when that start is earlier than `now` | `UpcomingViewModel.swift` | Keep the active-slot row while preserving its slot-start identity; pin a regression at 18:30 for an 18:00–22:00 slot | ✅ **closed by TF-01 scheduled-audit follow-up** |
| R50 | **One corrupt stored Contact makes All Contacts unavailable indefinitely.** The fail-closed repository read preserves the raw row and prevents silent data loss, but the screen has no way to show healthy rows alongside a visible corruption warning | `Repositories.swift`, `AllContactsViewModel.swift` | Add a corruption-aware read path that returns healthy contacts plus surfaced diagnostic state; never delete or silently skip the corrupt row; prove healthy contacts remain usable and the raw row survives | ✅ **closed by TF-03 / PR21**: `ContactRepository.fetchAllWithDiagnostics()` returns healthy contacts plus a diagnostic per undecodable row; `AllContactsViewModel` shows the healthy set with a corruption count/banner; `fetchAll()` stays fail-closed for callers (duplicate detection, import) that need all-or-nothing. Scope note: the tolerance covers `ContactRecord.toDomain()` decode failures (malformed JSON, invalid stored enum/UUID) — GRDB row decoding of the SQLite columns themselves still throws through `fetchAllWithDiagnostics()`, since a raw type mismatch there is a schema-level integrity problem this pass doesn't try to paper over. **R50 delivers visibility, not remediation** — identifying which contact is corrupt and repairing it is deferred to R53 |
| R53 | **Corrupt-row identification and repair remain unavailable.** R50's banner tells the user a row exists that couldn't be read, but nothing lets them find out which contact it was or do anything about it — no name, no repair action, and the reconciler deliberately skips corrupt rows on both its refresh and archive paths, so a corrupt row's banner never clears on its own. The banner copy currently reads "...needs attention" while no remediation path exists to act on; that wording is this gap's responsibility to resolve, not R50's, since it shipped describing a real (if incomplete) state honestly at the time | `ContactCorruptionDiagnostic`, `AllContactsViewModel.corruptionMessage` | Viable path for whoever picks this up: `ContactCorruptionDiagnostic` already carries `systemContactRef`, and the underlying system contact stays readable via `CNContactStore` even though the *stored* row doesn't decode — resolve that ref back to a `CNContact` for display, then offer re-import (rewrite the row from the system contact) or delete (drop the corrupt row for good). Natural home is alongside TF-15's export/delete surfaces rather than a standalone PR; that same slice should revisit the banner copy once a real action exists to point it at | TF-15 (or its own follow-up) |

### P1 — spec/doc integrity

| R | Defect | Where | Fix | PR |
|---|---|---|---|---|
| R16 | Edit Contact missing from the audited-screens table AND the audit suite (violates accessibility.md rule 10) | `ios/docs/accessibility.md:76-89`, `ScreensAccessibilityTests.swift` | Add row + test | ✅ **closed by TF-01 slice 1** |
| R17 | `NSContactsUsageDescription` is read-only copy; §11 requires the edit mention before write-back ships. `NSCalendarsFullAccessUsageDescription` is absent, and `CNContactBirthdayKey` is intentionally not requested until PR30 activates birthday ingestion | `project.yml:84-86`, `ContactsSource.swift` | Reword with PR27; with PR30, add the calendar key, re-add the birthday key, and disclose that read in the Contacts pre-prompt | PR27/PR30 |
| R18 | `PrivacyInfo.xcprivacy` has empty `NSPrivacyAccessedAPITypes`; SQLite/GRDB file-timestamp access will need required-reason entries at submission | `ios/Regards/PrivacyInfo.xcprivacy` | Populate against Apple's current category list during Phase 3 prep | PR34/§20 |
| R19 | Root markdown was exempt from link checks, and README referenced nonexistent `docs/DOMAIN_MODEL.md` and `android/` paths | `README.md`; `guards.yml` | README references ✅ **closed by TF-01 slice 1**; root Markdown checks cover repository root and `ios/docs/` | ✅ **closed by GitHub PR #39** |
| R20 | **CLAUDE.md misroutes agents (5 stale claims):** iPhone 15 destinations (CI uses 16 Pro); "Platform/ currently empty" (has Contacts adapter); PrivacyInfo said to live in `Resources/`; `pr3AuditCategories`/"PR3 follow-ups" naming (actual: `structuralAuditCategories`, "Sensory-audit carve-outs"); "snapshot job declared `if: false`" (it's a comment, no job) | `CLAUDE.md:37,41,78,80,92,111` | Rewrite (done in the same change set as this doc v1.0); future edits follow sibling-PR rule | ✅ **closed by TF-00 / GitHub PR #22** |
| R21 | `Package.resolved` gitignored while GRDB floats `from: 6.29.0` — contradicts reproducible-build claim | `.gitignore`, `project.yml` | Commit the resolved GRDB revision | ✅ **closed by GitHub PR #39** |
| R22 | `RegardsUITests` placeholder target in no scheme/workflow; `PlaceholderTests.swift` in unit bundle | `ios/RegardsUITests/`, `RegardsTests/PlaceholderTests.swift` | Delete both placeholders and the ownerless target | ✅ **closed by GitHub PR #39** |
| R23 | Mock and GRDB repositories previously had no shared contract tests | `RegardsTests/Data/RepositoriesTests.swift` | Shared contracts cover all six protocols on both backends, including failure and normalization semantics | ✅ **closed by TF-02 / GitHub PR #44** |
| R24 | Upcoming has focused representative-state, identity, ordering, boundary, failure, and transition-source tests but not its complete behavior suite. ContactDetail has spoken-label coverage only (`ContactDetailInteractionLabelTests`); its load, error, and derived-string behavior still has no unit suite. MergeDuplicates was also missing a suite at rebaseline. | `ios/RegardsTests/Features/` | Add the remaining coverage with the PRs that touch each VM | ContactDetail (`ContactDetailViewModelTests`) and Overdue/Upcoming action + `observeTracked()`/snooze suites ✅ **closed by TF-04 / PR22**; MergeDuplicates ✅ **closed by TF-01 modernization / GitHub PR #24**; remaining Upcoming reactive-pipeline suite PR25 |
| R25 | `CNContactsSource.fetchAllContacts` blocks a cooperative-pool thread for the full enumeration (5k-contact stall); `@unchecked Sendable` justified only by comment | `ContactsSource.swift:69, 98-125` | Move enumeration off the pool; synthetic 5k regression in PR21, physical A15 budget confirmation at TF-18 | ✅ **off-pool fix + synthetic 5k regression closed by TF-03 / PR21** (`runOffCooperativePool` dispatches `enumerateContacts` onto a GCD global queue instead of the calling cooperative-pool thread); physical on-device A15 budget confirmation remains TF-18 |
| R26 | Force-unwrapped calendar math in the engine (`date(byAdding:)!`) | `ReminderEngine.swift:162,203-205` | Eliminated by the R1 rewrite (incl. `resolveFeb29Fallback`) | ✅ **closed by PR16** |
| R27 | accessibility.md documents `waitForContactDetailReady` as canonical — the helper was reverted in PR #12 and doesn't exist | `ios/docs/accessibility.md:166-175` | Correct to the plain-identifier wait actually in use | ✅ **closed by TF-01 slice 1** |
| R28 | Simulator name drift: iPhone 15 (CLAUDE.md, docs), 15 Pro (`audit-stress.sh:25`), 17 Pro (CI) | multiple | Standardize on iPhone 17 Pro | ✅ **closed by TF-01 slice 1** |
| R29 | Unmerged `origin/ios/section-header-accessibility-label` (+7 lines) likely fixes the known ~20% "Label not human-readable" audit flake | branch | Merge; then 3× audit-stress to confirm flake death | ✅ **closed: branch merged in PR16; PR20–PR22 stress runs `30427994098`, `30457303394`, and `30514794147` passed 5/5 consecutively** |

### P2 — hygiene / hardening

| R | Item | Where | Fix | PR |
|---|---|---|---|---|
| R30 | Stale worktree with obsolete parallel scaffold (`generate_pbxproj.py`, old Domain, committed `.xcuserstate`) + prunable branch `claude/crazy-franklin-75fc28` + stray `.git/t9FBrGy` + ~16 merged local branches | `.claude/worktrees/`, `.git/` | Merged-branch cleanup completed (18 remote, 38 local) and automatic source-branch deletion enabled. Preserve the live worktree's 32 untracked files and the three patch-inequivalent `codex/pr24-pre-stack-rebase-20260730` commits; dry-run reports no prunable worktree. The patch-equivalent Android branch and empty `.git/t9FBrGy` are safe only after their active worktree is switched and exact targets are rechecked. | PR19 follow-up (open) |
| R31 | Domain coverage floor absent (§13 promises near-total); coverage collected but unenforced | `ios-ci.yml` | ≥95% xccov gate on the complete `Domain/**` source set (96.88% on merged head) | ✅ **closed by GitHub PR #39** |
| R32 | Guard gaps: domain-purity misses `@preconcurrency import` / `import class Contacts.X` / `import Network`; privacy-grep misses `NSURLConnection`, `CFSocket` | `guards.yml:33,46` | Shared source-boundary scripts reject every listed form, and canonical plus trusted-review workflows call those scripts | ✅ **closed by TF-01 trusted gate prerequisite (GitHub PR #26)** |
| R33 | Dead SwiftLint config: `function_body_length` threshold block while the rule is disabled | `.swiftlint.yml` | Remove the unreachable threshold block | ✅ **closed by GitHub PR #39** |
| R34 | Mock seeds miss ContactGroup/InteractionLog/occasion — merged chip, interactions card, occasion tags unreachable & unauditable; `UpcomingRowState.id = UUID()` per build breaks diffing (R36) | `MockRepositories.swift`, `UpcomingViewModel.swift` | Seed all three; stable cadence ids use `contactId+kind`, while persisted occasion rows use their reminder id to prevent same-kind collisions | ✅ **closed by GitHub PR #42** |
| R35 | Importer aborts mid-batch on first row error | `ContactsImporter.swift:56-64` | Per-row tolerance + counts | ✅ **closed by TF-03 / PR21**: `runFirstLaunchImport` catches and logs each row's write failure, counts it in `Result.failed`, and continues the pass; a failed row never joins the resolved-ref set, so a rerun retries it |
| R36 | (folded into R34) | — | — | ✅ **closed by GitHub PR #42** |
| R37 | `LSApplicationQueriesSchemes: []` while builder already emits `discord://` | `project.yml:80`, `DeepLinkBuilder.swift:43-45` | Add `discord` when deep links go live | PR26 |
| R38 | `TimeOfDay` precondition bypassed by synthesized `Decodable` — corrupt DB JSON can materialize minute=2000 into calendar math | `TimeOfDay.swift:10-13` | Custom `init(from:)` enforcing range | ✅ **closed by PR16** |
| R39 | Migrator seeded top-level Optional JSON as the text `"null"` instead of SQL NULL | `DatabaseMigrator.swift`, `Records.swift` | Append-only v2 normalizes legacy rows; new writes use SQL NULL; decoding remains defensive | ✅ **closed by TF-02 / GitHub PR #44** |
| R40 | Unused asset colorsets (`Ink`,`Muted`,`Background`) + two comments describing a code↔xcassets sync that doesn't exist | `Resources/Assets.xcassets`, `RegardsColors.swift`, `accessibility.md` | Delete or wire; fix comments | ✅ **closed by GitHub PR #42** |
| R41 | Contrast registry incomplete vs UI reality (white-on-accentInk CTAs, accentInk-on-surface, danger-on-surface unlisted) | `RegardsColors.swift:70-83` | Extend `contrastPairs` + tests | PR34 |
| R42 | `audit-stress.yml` header described obsolete PR-trigger behavior | `audit-stress.yml` | Header ✅ **closed by TF-01 scheduling-policy commit `f563915`**; GitHub PR #39 clarifies pending-run coalescing | ✅ **closed on current `main`** |
| R43 | Stale smoke-doc step ("Phase 0 scaffold" splash subtitle that no longer exists) | `accessibility-smoke.md:19-21` | Update script | ✅ **closed by TF-01 slice 1** |
| R44 | `LSApplicationCategoryType` = social-networking in project.yml while the listing plan says Productivity primary | `project.yml:94` | Align with §20 category decision | PR34 |
| R45 | 8.4 MB `Substack_banner.png` sitting at repo root (ignored but clutter); `.DS_Store` files | repo root | Move banner to journal assets outside the repo; OS files stay ignored | anytime |
| R46 | `InteractionLog` doc comment referenced nonexistent `ContactRepository.markCaughtUp`; `Channel.isAvailableOnIOS` remains an intentionally documented Android-port seam | `InteractionLog.swift`, `Channel.swift` | Keep the comment truthful and retain `isAvailableOnIOS` only while the Android port owns the divergent implementation | comment ✅ **closed by PR16**; zero-caller `Contact.effectiveWindow` removed by TF-02. TF-04/PR22 does not touch `Channel.swift` — its Log-other channel picker uses `Channel.allCases` directly, no `isAvailableOnIOS` filter — so "owned by PR22" overstated a PR that never calls it; corrected. The property stays zero-caller on iOS by design (it's `{ true }` for every case here; Android's port returns `false` for iOS-only channels), unowned by any iOS PR. |
| R47 | Invalid persisted timezone identifiers silently fall back to the device timezone, changing reminder timing without consent | `ReminderWindow.swift`, `Records.swift` | Validate IANA identifier and reject malformed persisted windows | ✅ **closed in PR16 review** |
| R48 | Slot-start snapping can schedule a future-due contact before `overdueAt`; repeated-hour snapping can choose a boundary from the wrong UTC occurrence | `ReminderEngine.swift` | Distinguish already-overdue from future-due targets; resolve fall-back boundaries relative to the search instant; regression tests | ✅ **closed in PR16 review** |
| R51 | `ContactsReconciler.redeterminedPreferredChannelValue` only re-derives a stale `preferredChannelValue` for `.phoneCall`/`.email`. `sms`/`whatsapp`/`signal` are phone-sourced and `facetime` is phone-or-email-sourced too (`ChannelCatalog.metadata`), so they can go just as stale — not a live bug today only because nothing before PR27 lets a user set or edit `preferredChannelValue` directly (importer-derived preferreds are always `.phoneCall`/`.email`), so there's nothing yet that could diverge for those four channels | `ContactsReconciler.swift` | Extend re-derivation to `sms`/`whatsapp`/`signal`/`facetime` as part of PR27 (`EditContactScreen`), the PR that first makes `preferredChannelValue` user-editable and turns this from a scope gap into a live correctness requirement | PR27 |
| R52 | Overdue and Upcoming ship Caught up / Snooze as real per-row buttons, not the swipe actions §10 describes: both screens are `ScrollView`/`RegardsCard`-based, and SwiftUI's `.swipeActions` only functions inside `List`. Per-row buttons are the accessible interim shape (an ordinary `Button` is VoiceOver-focusable and activatable with no custom-action wiring at all; `.accessibilityAction(named:)` can give a bespoke swipe gesture the same rotor-action parity independently of `List`, but only if someone builds and keeps that wiring in sync with the gesture — buttons get it for free by construction, not because `List` is the only route to it) | `OverdueScreen.swift`, `UpcomingScreen.swift` | Deliberate, owner-approved deviation (§14 PR22 review) — no fix required now; revisit as a `List`-backed swipe redesign if TF-16 polish scope wants the literal gesture | TF-16 candidate |
| R54 | **`SchedulingPass.snooze` has no tracked/cadence precondition.** It writes a pending cadence `ScheduledReminder` for any contact that merely exists, regardless of whether `Contact.tracked` is `true` or `cadenceDays` is set — neither this §14 PR22 DB-only stub nor either shipped caller (`OverdueViewModel.snooze`, `ContactDetailScreen`'s Snooze control) checks first. Not reachable today: both callers only ever offer Snooze for a row already computed as overdue, which requires `tracked && cadenceDays != nil` by construction — flagged, not fixed, this late in TF-04 (staged review round 6) | `SchedulingPass.swift` | Add the precondition once TF-07 gives `SchedulingPass` its full read/write surface (it needs a `ContactRepository` read this stub deliberately doesn't have); reject or no-op a snooze for an untracked or no-cadence contact instead of silently writing a reminder nothing will ever surface | PR25 |
| R55 | **Corrected, round 7: the previous text here was wrong** — `SchedulingPass.snooze` already resolves its 7-day push through the persisted reminder window's own `timeZone`; `AppRuntime.init` builds the scheduler's calendar with `Self.calendar(for: window.timeZone)`, not `userCalendar` (fixed in round 6, misdiagnosed in round 6's own register entry). The real, remaining gap: `AppRuntime` — `window`, `userCalendar`, and `scheduler` alike — is constructed once at launch (`AppLaunchCoordinator.runtime` is set once and only cleared to `nil` on retry/reset) and never rebuilt. A window-timezone edit mid-session would leave `scheduler`'s calendar on the stale zone for the rest of the session. Same root cause R9b already names ("a stored-window change does not refresh"), and currently unreachable for the identical reason R9b gives: `ReminderWindowsScreen` is still the display-only mock (`.constant` Toggle, no save path), so there is no shipped way yet to trigger the edit this describes | `AppEnvironment.swift`, `AppLaunchCoordinator.swift` | Folds into R9b's fix: when TF-05/PR23 gives `ReminderWindowsScreen` a real save path and rebuilds observable state on a window edit, rebuild `AppRuntime` too so `scheduler`'s calendar picks up the new timezone, not only `UpcomingViewModel`'s window | TF-05 (PR23) |
| R56 | **Contact Detail's "N days overdue" status and next-reminder label never reflect a persisted Snooze.** `ContactDetailViewModel` has no `ReminderRepository` of its own — `overdueSummary` computes purely from `Contact`'s own fields (`cadenceDays`, `lastInteractedAt`, `createdAt`), unlike `OverdueViewModel.makeOverdueRow`/`UpcomingViewModel.buildRows`, which both fold a pending snooze's `scheduledFor` into their date math. Right after a successful Snooze on this screen, the status row still says "N days overdue" against the same stale cadence math — a false statement on the success path, live today (staged review round 8) — while `nextReminderLabel`'s separately-tracked hardcoded "Today, 6:30 pm" (R11) stays equally stale regardless. Not fixed in TF-04: it needs a live read (or `ValueObservation`) this §14 PR22 slice was never scoped to carry, and touches every call site that constructs this view model | `ContactDetailViewModel.swift`, `ContactDetailScreen.swift` | Wire `reminders`/a persisted-reminder read into `ContactDetailViewModel` and fold the pending snooze into `overdueSummary` and `nextReminderLabel` the same way the other two screens already do | TF-07 (PR25) |

## 20. Release engineering & App Store playbook

### Versioning & branching

- `main` is always releasable; feature branches → PR → a merge method allowed
  by the active main ruleset. Repository settings expose squash, rebase, and
  merge, but ruleset `15488213` currently admits only rebase and merge. Version
  `CFBundleShortVersionString` stays `0.1.0` until the internal TestFlight
  feature freeze, then becomes `1.0.0` (decision #35's version rule survives
  its expired date). `CFBundleVersion` increments every TestFlight upload
  (integer, monotonic). Tag releases `ios-v1.0.0`; release notes come from
  merged PR titles.
- Freeze rules: after the external TestFlight candidate, only P0/P1 fixes;
  every merge re-runs the full checklist below.

### App Store Connect — record state & required fields

Created 2026-04-15: name **"Regards: Stay in Touch"** (bare "Regards" was taken), bundle `com.consideratesoftware.regards`, SKU `regards-ios`, iOS platform. Everything else is empty. Fill order:

**Before first TestFlight upload:**
1. Subtitle (30 chars): `Private personal CRM` (fallbacks: `Local-first contact reminders`, `No cloud. No account. No ads.`).
2. Keywords (100 chars): `stay in touch,friends,family,reminder,contacts,personal crm,relationships,keep in touch,private,offline`.
3. Category: **Primary Productivity, Secondary Lifestyle** (final call at entry; update `LSApplicationCategoryType` to match, R44).
4. Age rating questionnaire → 4+.
5. **Privacy Policy URL** (required even collecting nothing) — one page on GitHub Pages: "Regards collects no data. The app has no network access by design." + contact email.
6. App Privacy section → **"Data Not Collected"** every category. This is the centerpiece; triple-check.
7. TestFlight beta app description + external group; export compliance: `ITSAppUsesNonExemptEncryption = false` in Info.plist (only OS-provided encryption) so uploads skip the crypto questionnaire.

**Before App Store submission:**
8. Description (4000 chars): lead with the emotional hook from journal post #1 ("the friend from your wedding you haven't called in a year"), then reminder windows → one-tap deep links → provable privacy → what it deliberately won't do → one-time price. Mirror the post-#1 voice; don't write marketing-speak.
9. Promotional text (170 chars, hot-editable): launch framing.
10. Support URL: GitHub Issues. Marketing URL: the Substack.
11. Screenshots: 6.9"/6.7" set (1320×2868 / 1290×2796), 3–10 shots: Overdue, Upcoming, Contact Detail (deep-link button visible), Reminder Windows editor, Transparency screen, widget. Frame with one-line captions; the Transparency shot is the differentiator — don't bury it.
12. App icon 1024×1024 (no alpha/rounded corners) — export from Bakery per the asset plan.
13. Copyright `© 2026 Considerate Software LLC`. Trade rep info (Korea) skip unless targeting KR at launch.
14. Pricing: Tier-A $4.99 anchor + auto-pricing per storefront per §4 tiers; verify IN/BR land ₹99-class/R$9.90-class. IAPs: `com.consideratesoftware.regards.unlock` (non-consumable), `.tip.coffee`, `.tip.thanks`, `.tip.feature` — created, localized, attached to the submission build. **Small Business Program enrollment confirmed before launch.**
15. App Review notes: no account needed; no demo credentials; "This app contains no networking code by design (ATS uses strict defaults with every exception disabled; source is public at github.com/consideratesoftware/RegardsMobileApp). You will observe zero outbound traffic. Contacts write access is used only for user-initiated single-field edits."

### Pre-submission verification (run at freeze AND at submission)

1. Full CI green on the release SHA; audit-stress 5/5 ×3.
2. Fresh-install device pass: onboarding → permission grants AND denials → import → windows edit → notification fires in-window → deep link opens → caught-up → digest → widget → purchase (sandbox) → restore → export → delete-everything.
3. **Network capture session (Proxyman on device): zero outbound flows** outside StoreKit/OS. Record it — this becomes the §11 transparency video.
4. `PrivacyInfo.xcprivacy` required-reason entries verified against Apple's current list (R18).
5. VoiceOver full-flow smoke; Dynamic Type accessibility5 spot pass.
6. DB migration test from a v1-schema store (simulating a Phase-0-era TestFlight install upgrading).
7. Archive builds reproducibly from a clean checkout (`xcodegen generate && xcodebuild -onlyUsePackageVersionsFromResolvedFile archive`).

### Rejection playbook

Most likely flags for this app: (a) **2.1 performance/completeness** — reviewer can't see reminder value quickly → the review notes include a 60-second "how to see a reminder fire" script (set cadence 1 day, window = now); (b) **5.1.1 permission purpose strings** — keep strings specific (R17); (c) **privacy label mismatch** — we collect nothing, labels say so, PrivacyInfo agrees; (d) IAP restore/trial confusion — Restore button visible in Paywall AND Settings. Respond in Resolution Center within 24h; if metadata-only, fix without re-review; never argue, clarify.

### Launch-day runbook

Release the approved build manually at ~9am ET → verify live in 2–3 storefronts → publish journal post #10 (launch) → Product Hunt launch → press emails (MacStories, Privacy Guides forum, 9to5Mac tips, r/privacy where rules allow) with the press kit (one-pager, screenshots, network-capture video link, source link) → pin the GitHub Discussions welcome thread → watch crash/feedback channels; hotfix bar is P0-only for week 1.

## 21. Maintenance & operations playbook

**Weekly (steady state):** triage GitHub Issues + store reviews (respond to every review, year 1); check TestFlight/App Store crash reports (organizer); scan support inbox; merge dependabot-equivalent manual checks — GRDB releases reviewed, bumped deliberately with `Package.resolved` diff + full test pass (never auto-bump; decision #37).

**Per release (any version):** the §20 pre-submission verification list, scaled to change size; sibling doc updates; refreshed Exodus report (Android, once it exists) and network-capture spot check; tag + release notes; journal post if user-visible.

**Quarterly (year 1):** geo-tier pricing review vs FX drift (document in a journal post per §15.6); competitive-landscape refresh of the §4 table; accessibility re-audit with the newest Xcode audit categories; dependency + toolchain review.

**OS-beta season (June–September, annually):** from WWDC beta 1, run the full suite + manual smoke on each beta of iOS N+1; fix deprecations before GM; re-verify ATS/privacy-manifest behavior changes and the Contacts/EventKit permission UX (Apple reshapes these regularly — iOS 17 did for Calendar; iOS 18 did for Contacts with the limited-access picker: **test limited-Contacts-authorization mode explicitly**, it's the likeliest silent breaker for this app; if `CNAuthorizationStatus.limited` exists in the target SDK, the importer and reconcile paths must handle a partial universe without archiving unseen contacts — add that test before the first fall-OS release). The same "don't archive on an ambiguous read" posture applies to `.authorized`: a ref missing from a `fetchAllContacts()` result — wholesale-empty or only partially populated — only archives once it's stayed missing for at least `ContactsReconciler.archiveDebounceFloor` (5 minutes), confirmed by a later `.authorized` pass that still doesn't see it, since a single miss (or two of them moments apart) is equally consistent with a mid-restore resync as with a genuine deletion (§7). That floor is measured across relaunches, not just within one process's uptime — `AppLaunchCoordinator` persists the "first seen missing" timestamp (hashed, in `MissingContactRefStore`) so a device restart or app kill between the two passes doesn't reset the clock and leave a genuine deletion stuck unarchived forever (§7).

**Incident response (no telemetry by design, so signals are humans):** crash spike = App Store crash organizer + review keywords + support mail. Reproduce → hotfix branch from the release tag → expedited review request if P0 (data loss / notifications dead / launch crash). The user-initiated diagnostic mailto is the only "log" pipeline; keep its payload useful (app version, OS, device, last-migration id, counts — never contact data).

**Data-integrity guarantees:** any future migration `vN` ships with an upgrade test from every prior shipped schema; export format is versioned (`"exportVersion": 1`) and import-tested (V2 sync candidate depends on it); "Delete everything" must remain instant and total.

**Community/comms:** journal cadence per §11b (biweekly floor, event posts on milestones); roadmap board updated when scope decisions happen, not after shipping; V2 candidates graduate only through a decisions-log entry with a scope cut somewhere else — the UpHabit scope-creep lesson is standing policy.

**Android start gate (from §14):** iOS crash-free ≥99.5% over 2 trailing weeks, support <30 min/day, and the §19 register at zero open P0/P1. Then the port begins with the domain test suite translation, not with UI.

---

*End of document.*
