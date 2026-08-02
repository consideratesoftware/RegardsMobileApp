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
- **UI:** SwiftUI, iOS 17.0 minimum target.
- **Persistence:** GRDB.swift (SPM, currently `from: "6.29.0"` — pin via committed `Package.resolved`, R21).
- **Async:** Swift Concurrency. ViewModels are `@MainActor @Observable`.
- **Notifications:** `UNUserNotificationCenter`, non-repeating `UNCalendarNotificationTrigger`.
- **Contacts:** `Contacts.framework` behind the `ContactsSource` protocol (`ios/Regards/Platform/Contacts/`).
- **Calendar:** EventKit behind a `CalendarSource` protocol (Phase 1D).
- **Deep linking out:** `UIApplication.open(_:)` behind a `DeepLinker` protocol; schemes declared in `LSApplicationQueriesSchemes` only where universal links don't exist (§8).
- **Billing:** StoreKit 2 (Phase 2).
- **Project generation:** XcodeGen from `ios/project.yml`. **Never hand-edit `Regards.xcodeproj`** — CI enforces determinism (`xcodegen generate && git diff --exit-code`).
- **Toolchain:** CI pins the runner's stable Xcode (currently 26.6; simulator pinned to iPhone 17 Pro with the latest installed iOS runtime). `project.yml` declares `xcodeVersion: "26.0"` for local work on Xcode 26. Before Phase 3, pin CI to the exact Xcode version used for App Store submission, run the full suite on the current iOS beta, and record the choice in the decisions log (see §21 "OS-beta season").
- **Lint:** SwiftLint `--strict`. Custom rule `button_requires_accessibility` flags `Button { Image/Spacer/EmptyView }` without `.accessibilityLabel`.

### Android (follow-on port; `android/` does not exist yet)

- Kotlin 2.x, Jetpack Compose + Material 3, Room + SQLCipher, Coroutines/Flow, `NotificationManagerCompat` + `AlarmManager.setExactAndAllowWhileIdle` (WorkManager fallback if exact alarms refused), ContactsContract, Play Billing 7. Min SDK 28.
- The Swift domain layer + its test suite is the porting reference. No KMP — we port, not share (decision #2, #20).

### Shared

- This document is the single source of truth. The v0.5 plan for a sibling `DOMAIN_MODEL.md` is **dropped** (decision #24): with the Swift domain layer + tests as the executable spec, a third artifact would drift. README references to `docs/DOMAIN_MODEL.md` must be removed (R19).

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
  occasionTime: TEXT                -- "HH:mm" morning-of time for birthday/anniversary notifications, default "09:00"
  digestHorizonDays: INTEGER        -- Upcoming view horizon (7/14/30), default 14

ScheduledReminder
  id: UUID
  contactId: UUID -> Contact.id (ON DELETE CASCADE)
                                    -- for a virtually merged group this is the PRIMARY contact's id
  kind: TEXT                        -- 'cadence' | 'birthday' | 'anniversary' | 'custom_occasion'
  occasionDate: TEXT?               -- ISO "MM-DD" for annual kinds; null for cadence
  occasionLabel: TEXT?              -- free-text for anniversaries/custom
  scheduledFor: INTEGER             -- epoch seconds, ALREADY SNAPPED to an allowed-window slot start (§9)
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
- Deleted system contacts → set `archivedAt` (never hard-delete; cadence/log history stays for potential re-add).
- Changed contacts → refresh `displayName`, `photoRef`, `phonesJson`, `emailsJson`, birthday/dates inputs.
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

`Contact.reminderWindowOverride` (full `ReminderWindow` JSON) replaces the global window when non-null. Resolution happens in **one** place — SchedulingPass computes `effectiveWindow = contact.reminderWindowOverride ?? global` and passes it down; the engine never reaches around its inputs. (Shipped gap: `UpcomingViewModel` hardcodes `.defaultV1()` and ignores both the repository and the override — R9.)

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
6. **No double-up.** If a contact has both an overdue cadence reminder and an occasion today, the occasion wins; the cadence reminder is marked `user_caught_up` when the user acts on the occasion (a birthday call counts as staying in touch).

### Re-evaluation triggers (all route through SchedulingPass, §9a)

- "Caught up" → log interaction, set `lastInteractedAt`, cancel pending reminder(s) for the contact/group, reschedule.
- Snooze (1 week) → push the pending reminder's `scheduledFor` to `nextAllowedSlot(from: firedAt + 7d)`; state stays `pending`; no interaction is logged and `lastInteractedAt` does **not** move (decision #31).
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

Single `actor SchedulingPass` (App layer, constructed in `AppEnvironment`), the only writer of `ScheduledReminder` rows and OS notifications.

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

Nine screens + one widget family in V1. **As-built decision (#32):** navigation is a **4-tab `TabView`** — Overdue, Upcoming, Contacts, Settings — each tab owning its own `NavigationStack` with per-tab `NavigationPath`, so a push inside Overdue never bleeds into Upcoming and tab state survives switching. v0.5's "one Home screen with a segmented control" is superseded; the segmented Overdue/Upcoming pill at the top of both list screens **stays** as a glanceable count + one-tap cross-switch (it displays live counts, which the tab bar can't). `ContactDetailScreen` is constructed by a factory (`contactDetail(for:)`) so each push gets a fresh VM — never rely on SwiftUI view identity to reset it (regression-tested).

1. **Overdue (Home)** — overdue contacts sectioned by priority tier. Row: photo, name, "2 weeks overdue", channel icon (tap = open deep link), merged-group chip where applicable. Swipe: **Caught up** / **Snooze 1 wk**. Footer shows the live next-digest time (from persisted reminders — the shipped hardcoded "6:00 pm" strings are R11). Empty state: "All caught up."
2. **Upcoming** — reminders in the next `digestHorizonDays` (7/14/30, user-set), grouped by day, from **persisted** `ScheduledReminder` rows via `ValueObservation` (R10). Rows show contact, channel, kind tag (birthday/anniversary), scheduled time. Swipe: **Reach out now** (opens deep link + logs interaction + advances cadence) / **Mark caught up**. Horizon picker lives in the nav bar (shipped inert button R11).
3. **All Contacts** — every tracked contact; search (`.searchable`), sections by priority tier, group-membership indicator, tap → Contact Detail. Untracked imports reachable via a filter toggle (Phase 1B) so users can start tracking someone new.
4. **Contact Detail** — hero (photo/name/priority), cadence card (cadence, **live** next reminder, last interaction, status), channel card with **working "Open [channel]"** button, actions: **Caught up** (logs + reschedules), **Snooze 1 wk**, **Log other channel…**; interactions list (last 8); Regards-local notes with "private to Regards" footnote; **Edit contact** (→ screen 5); reminder-window override editor entry; "Merged with…" disclosure when grouped (→ screen 6 context).
5. **Edit Contact** — real form (`TextField`s) mirroring system-contact fields: name, phones, emails, postal addresses, birthday, anniversary. Save = partial-field `CNSaveRequest` write-back of touched fields only; Cancel/back always available (the shipped screen hides the back button with no-op Cancel/Save — the R13 nav trap). Regards-local `notes` visible but labeled not-written-back. Write-permission-denied state links to Settings.
6. **Merge Duplicates** (Settings entry) — ranked candidate pairs (§7 heuristic) with side-by-side preview; user picks the primary face; **Confirm creates a `ContactGroup` row** (shipped gap R12: nothing persists); one-tap Undo (delete group); **Skip** dismisses a pair persistently (store dismissed pair hashes locally); manual "link two contacts…" flow for heuristic misses.
7. **Settings** — Reminder windows (→ screen 9), quiet hours, occasion notification time, Upcoming horizon, digest preview, Find duplicate contacts, notification permission status + re-prompt, entitlement card (trial countdown / unlock / restore purchases / tip jar, Phase 2), **Export my data** (JSON to Files), **Delete everything** (wipe DB + reset first-run), Transparency screen, "Behind the App" (journal link — the app's one outbound *user-initiated* Safari link; it does not violate §11 because it's `openURL` to the system browser, no in-app networking), Contact support (mailto with prefilled diagnostics), Onboarding replay.
8. **Onboarding** — 3 screens: (a) concept sell ("who have you been meaning to call?"), (b) Contacts permission pre-prompt → system prompt, (c) optional Calendar pre-prompt + pick-your-first-3-contacts starter (search, set cadence+channel inline). Gated by `UserProfile.onboardingCompletedAt` in the launch path (shipped gap: only reachable from Settings preview, R14). Denial paths: Contacts denied → explainer + Settings deep link + browse-only mode.
9. **Reminder Windows** (pushed from Settings; promoted to a first-class Features folder, decision #33) — **live editor**, not the shipped display-only mock (R9): day pills toggle `allowedDaysMask`, time ranges add/edit/remove with overlap validation, quiet-hours editor (wrap allowed), zero-capacity configs refuse to save with inline error, writes through `ReminderWindowRepository` and triggers `SchedulingPass.runFull()`.

Plus **Transparency** (static, shipped) under Settings — plain-language privacy proof with links out (wire the three inert "Open" rows to `openURL`, R15).

**Widget family (Phase 2, §14):** small (top-3 overdue), medium (top-5 + per-icon deep links via `widgetURL`), Lock Screen circular/inline count. Reads a **read-only GRDB connection** on a shared App Group container (`group.com.consideratesoftware.regards`); main app calls `WidgetCenter.shared.reloadAllTimelines()` after every SchedulingPass. No network, no new permissions.

**Design system:** `RegardsDS` tokens (colors incl. WCAG-checked pairs in `RegardsPalette.contrastPairs`, typography, spacing) + primitives (`Avatar`, `ChannelGlyph`, `Tag`, `Wordmark`, `RegardsNavBar`). Rule: **no inert interactive-looking controls in shipped UI** — Phase 0's muted-stub convention (`RegardsNavBar` renders nil-handler actions as visibly disabled) was correct for a shell and is deprecated the moment the real affordance lands; every stub is enumerated in §19 and each Phase 1 PR must wire or remove the stubs in the screens it touches.

**Accessibility is release-blocking, and reviewed on every PR.** As of 2026-08-02 the automated audits no longer run on pull requests: the 1x audit runs on merges to `main`, and the 5x stress sweep runs on merges, nightly, and on demand before a release (both were `macos-latest`, averaging 33 min a run at 10x billing, and a flake in either blocked unrelated PRs). What still gates a PR is the `pr-accessibility` reviewer and the manual VoiceOver smoke below; what gates a release is a green 5x sweep, run via `workflow_dispatch` before cutting a build. A regression now surfaces on `main` rather than on the PR that caused it, so run `ios/scripts/audit-stress.sh` locally before any UI-touching push. `RegardsAccessibilityTests` runs `performAccessibilityAudit()` per screen; structural categories (`elementDetection`, `sufficientElementDescription`, `trait`) gate today; sensory categories (`contrast`, `hitRegion`, `dynamicType`, `textClipped`) are carved out until PR34 flips `structuralAuditCategories` → all categories (tracked in `ios/docs/accessibility.md` "Sensory-audit carve-outs"). Every screen gets a row in that doc's audited table — Edit Contact is currently missing its row *and* its test (R16). Manual VoiceOver smoke (`ios/docs/accessibility-smoke.md`) before any UI-touching merge. Dynamic Type through `accessibility5`, Reduce Motion respected (splash already does), 44×44pt targets.

## 11. Privacy & security — verifiable, not marketing

The claim: **"no data collected, no call-home, ever."** Stacked technical, legal, and transparency guarantees make it provable.

### Data handling inside the app

1. **Contacts access is read + scoped-write, always local.** Read: name, photo, phones, emails, postal addresses, birthday, anniversary dates, system identifier. Write: only user-edited fields via `CNSaveRequest`, never deletions/bulk/merges. **Before PR27 ships write-back, `NSContactsUsageDescription` must be updated to mention in-app editing** (R17) — informed consent; current copy is read-only.
2. **Minimum necessary fields imported.** Nothing beyond the list above.
3. **Calendar access optional, local-only, read-only.** iOS 17 key: `NSCalendarsFullAccessUsageDescription` (add with PR30; consider read-only access level if the entitlement/API surface allows — we never write). Denial/revocation never breaks the app; birthdays fall back to Contacts.
4. **All data at rest encrypted.** iOS: `NSFileProtectionCompleteUntilFirstUserAuthentication` on the DB (shipped in `DatabaseFactory.makeDatabase()`). Android: SQLCipher + Keystore.
5. **Data export / delete.** JSON export to Files; "Delete everything" wipes DB + resets first-run.
6. **Permission transparency.** Pre-prompt screens before each system prompt explaining exactly what we read and why.

### Technical anti-call-home guarantees

**Android — nuclear tier:** no `android.permission.INTERNET` in the manifest → the kernel denies socket creation to the app's UID. Rules out any networked SDK forever. Enforced in code review + a manifest CI guard when `android/` exists.

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
    App/                          — RegardsApp (@main), AppEnvironment (DI), tab root, screen factories
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
      Contacts/                   — ContactsSource (CNContactStore adapter), ContactsImporter
                                    [PR21 adds reconciliation; PR27 adds ContactsWriter]
      Notifications/              — [PR24] NotificationScheduling adapter (UNUserNotificationCenter)
      Calendar/                   — [PR30] CalendarSource (EventKit)
      DeepLinks/                  — [PR26] DeepLinker (UIApplication.open)
      Billing/                    — [PR32] StoreKit 2 entitlement service
    DesignSystem/                 — RegardsDS tokens, RegardsColors (+contrastPairs), Primitives/
    Features/
      Overdue/  Upcoming/  Contacts/  ContactDetail/  EditContact/
      MergeDuplicates/  ReminderWindows/  Onboarding/  Settings/ (incl. TransparencyScreen)
      Shared/                     — RegardsNavBar etc.
      Paywall/                    — [PR32]
    Resources/                    — Info.plist (generated), Assets.xcassets
    PrivacyInfo.xcprivacy         — privacy manifest (note: lives at Regards/ root, not Resources/)
  RegardsWidget/                  — [PR31] WidgetKit extension target (App Group, read-only DB)
  RegardsTests/                   — swift-testing unit bundle (Domain, Data, Platform fakes, VMs)
  RegardsAccessibilityTests/      — XCUITest audit bundle (merge-gating)
  RegardsUITests/                 — placeholder; NOT in the default test plan (repurpose or delete, R22)
  docs/                           — accessibility.md, accessibility-smoke.md
  scripts/                        — audit-stress.sh (5× local audit runs before UI-test pushes)
```

Each screen folder owns `*Screen.swift` + `*ViewModel.swift` where stateful. All feature code talks to `any *Repository` protocols — never concrete GRDB types — so the mock↔production swap stays a one-line change in `RegardsApp`.

### Android (follow-on; unchanged plan)

```
:app  :feature:{overdue,upcoming,contacts,contact-detail,edit-contact,merge-duplicates,onboarding,settings,paywall}
:widget  :domain (pure Kotlin port of iOS Domain + same tests)  :data (Room+SQLCipher)
:platform:{contacts,calendar,notifications,deeplinks,billing}
```

## 13. Testing strategy

**Shipped suites (census 2026-07-01):** ReminderEngineTests (14), ContactsImporterTests (13), RepositoriesTests (10), AnnualRecurrenceTests (9), DuplicateDetectorTests (8), DeepLinkBuilderTests (7), DatabaseMigratorTests (5), ContactAccessibilityTests (5), OverdueViewModelTests (4, incl. solid spring-forward day-count regressions), ColorContrastTests (3), placeholder (1) — 79 tests in the unit bundle. Plus 13 XCUI audit tests (11 screen audits + 1 navigation-distinctness regression + launch), and 1 placeholder in the out-of-plan `RegardsUITests` target.

**Standing requirements:**

- **Domain: exhaustive unit coverage, CI-enforced floor.** PR19 adds a coverage gate: ≥95% line coverage on `ios/Regards/Domain/**` via `xccov` in the unit-tests job (the v0.5 "100%" aspiration meets reality at 95% + mandatory tests for every listed edge case). The floor may only go up.
- **Engine edge cases that MUST have tests after PR16** (each currently missing and each guards a shipped or latent defect): a window **on** a DST transition day (US 2026 transitions Mar 8 / Nov 1 are Sundays — the shipped tests use weekday-only windows and dodge the bug; add Sunday-inclusive windows and a synthetic zone like `Australia/Lord_Howe` for the 30-min case), fall-back duplicated-hour disambiguation, spring-forward nonexistent slot-start, midnight-boundary walk, contiguous-range collapse, wrap-rejection validation, degenerate-window → nil, quiet-hours-consume-everything → nil, same-day-late occasion fires today, never-contacted anchor = createdAt, slot-start snapping equality.
- **Deep-link parametric completeness:** one case per `Channel` (a test asserts the parametric list covers `Channel.allCases`), plus the property `isValid ⟹ build != nil` for every link-bearing channel, plus the specific regressions: facetime-email, m.me URL, `@handle` telegram, non-http custom scheme.
- **SchedulingPass (PR25):** fake repos + fake `NotificationScheduling`; assert idempotence, orphan cancellation, group-collapse (one reminder per group), digest identity stability, 60-cap behavior.
- **Migrations:** fresh-create and v1→v2 upgrade round-trips for every table; migration tests may never be deleted, only added.
- **Repositories:** contract tests run against both `MockRepositories` and GRDB implementations (shared assertions) so mocks can't drift from production semantics (R23).
- **ViewModels:** every VM gets a unit suite (Upcoming/ContactDetail/MergeDuplicates are missing today, R24).
- **Snapshot tests (PR34, decision #34):** adopt `pointfreeco/swift-snapshot-testing` (test-target-only dependency — it never enters app sources, so no privacy-grep implications) for the 9 screens × key states (empty / populated / all-caught-up / trial-expired / post-purchase). The `ios-ci.yml` snapshot placeholder comment becomes a real job.
- **StoreKit (PR32):** StoreKitTest configuration file + sandbox smoke: purchase, restore-from-fresh-install, trial expiry math.
- **Accessibility:** `ios/scripts/audit-stress.sh` (5 consecutive runs) locally before any UI-test push. In CI both audits moved off the pull-request path (see §10): the 1x audit runs on merges to main, the 5x sweep runs on merges, nightly, and on demand before a release. Test-pattern rule (learned the hard way, PR #11/#12): don't `waitForExistence` on predicate-matched queries; plain element queries for waits, predicates for read-after-known.
- **Manual:** VoiceOver smoke per `ios/docs/accessibility-smoke.md` before UI-touching merges; a 5k-contact synthetic address book performance pass in Phase 2 (R25).

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
throughput. If scope must move, cut in this order: PR35 localization
scaffolding → medium widget (ship small+lock only) → snapshot breadth (keep 4
core screens). Never cut accessibility gates, privacy invariants, or the §9
contract.

### Phase 1R — Remediation (Jul 6–10) — fix what's wrong before building on it

| PR | Scope | Key acceptance criteria |
|---|---|---|
| **PR16** | Engine contract fixes: wall-clock slot math, `Date?` return + degenerate handling, wrap/timezone rejection in `ReminderWindow` validation, never-contacted = `?? createdAt`, same-day-late occasion, eligibility-safe slot-start snapping in `batch` semantics | R1, R3–R6, R8, R47–R48 engine portions closed; all §13 engine edge-case tests green; no force-unwraps in changed paths (R26) |
| **PR17** | Channel/validation fixes: facetime email pass-through, m.me normalization, `@` stripping, custom = any-scheme URL; `isValid ⟹ build` property test for link-bearing channels; parametric covers `allCases` | R2, R7 closed |
| **PR18** | Truth pass on docs + merge the orphan: merge `origin/ios/section-header-accessibility-label` (+7 lines, likely kills the 20% audit flake); fix CLAUDE.md's 5 stale claims; README (drop `docs/DOMAIN_MODEL.md` + `android/` refs); accessibility.md (remove ghost `waitForContactDetailReady` reference, add Edit Contact row + audit test); unify simulator name (iPhone 17 Pro) across CLAUDE.md/docs/scripts | R16, R19, R20, R27–R29 closed; audit-stress 5/5 green ×3 consecutive runs |
| **PR19** | Repo + CI hygiene: commit `Package.resolved`; `git worktree prune` + delete stale worktree/branches; root-markdown link-check job; Domain coverage floor (≥95%); guard hardening (R32, completed by the TF-01 trusted-gate prerequisite); remove dead SwiftLint `function_body_length` config; seed mocks with a ContactGroup + InteractionLogs + an occasion so all UI states are reachable/auditable; delete `.git/t9FBrGy` | R21, R30–R34 closed; all 4 workflows green |

### Phase 1B — Production wiring (Jul 13–17) — the mock era ends

| PR | Scope | Key acceptance criteria |
|---|---|---|
| **PR20** | Flip `@main` to `AppEnvironment.makeProduction(database: DatabaseFactory.makeDatabase())`; migration `v2` (§7 columns); first-launch import flow; onboarding gate via `onboardingCompletedAt`; splash transitions on actual load completion | Fresh install on device: onboarding → Contacts permission → import → populated tabs. Mock path stays for previews/UI tests via launch argument |
| **PR21** | Reconciliation: launch/foreground + `CNContactStoreDidChange` re-import; archive-on-delete; refresh names/photos/handles (`phonesJson`/`emailsJson`); importer per-row fault tolerance (R35) | Delete/re-add/rename a contact in the system app → Regards reflects it next foreground; history survives archive |
| **PR22** | The core loop: Caught up / Snooze / Log-other wired everywhere (Detail buttons, Overdue+Upcoming swipe actions) → `InteractionRepository.append` + `lastInteractedAt` + targeted SchedulingPass stub (DB-only until PR25); stable row identities (R36) | Marking caught-up moves the contact out of Overdue instantly and logs an interaction; snooze pushes 7 days; VM tests |
| **PR23** | Reminder-window persistence: ReminderWindows screen becomes a live editor (days/ranges/quiet-hours/occasion-time/horizon), writes via `ReminderWindowRepository`, zero-capacity refuses save; Upcoming/Overdue read the real global window + per-contact overrides (R9) | Edited windows survive relaunch and visibly re-shape Upcoming |

### Phase 1C — Notifications end-to-end (Jul 20–24) — the product starts existing

| PR | Scope | Key acceptance criteria |
|---|---|---|
| **PR24** | `Platform/Notifications` adapter (`NotificationScheduling`), permission pre-prompt + request in onboarding step (c) and Settings, notification categories/actions (Caught up / Snooze / open) | Local notification fires on device at a window boundary; actions round-trip |
| **PR25** | `SchedulingPass` actor: full + targeted runs, digest batching (slot-start snapping, `digest-{epoch}` identity), occasion scheduling from Contacts source, no-double-up rule, orphan cancellation, launch/foreground reconcile; Upcoming switches to `ValueObservation` over persisted rows (R10); live digest labels (R11) | Idempotence + reconcile tests green; airplane-mode device test: overdue contact → digest at next window open |
| **PR26** | Deep-link execution: `DeepLinker` adapter, channel taps wired in all 4 surfaces, notification tap-through routing (digest → Overdue; single → Contact Detail), `LSApplicationQueriesSchemes: [discord]`, `reminder_tap` interaction logging | Tapping WhatsApp row on device opens WhatsApp to the contact; R37 closed |

### Phase 1D — Editing, merging, onboarding, calendar (Jul 27–31)

| PR | Scope | Key acceptance criteria |
|---|---|---|
| **PR27** | Edit Contact: real form, dirty-field tracking, partial `CNSaveRequest` write-back via `ContactsWriter`, re-fetch after save, nav trap fixed (R13), write-denied state, `NSContactsUsageDescription` reworded (R17) | Edit phone on device → visible in system Contacts app; only touched fields written; audit test added |
| **PR28** | Merge for real: confirm→`ContactGroup` write, group-aware SchedulingPass (one reminder/group, member-max interaction), one-row-per-group in Overdue/Upcoming, unmerge, persistent skip, manual link, detector fed full handle sets (R12) | Two "Mom" entries → one reminder; unmerge restores; group chip reachable and audited |
| **PR29** | Onboarding: 3-screen flow in launch path (R14), pre-prompts, first-3-contacts starter, denial paths | Fresh-install TestFlight-ready first-run |
| **PR30** | Calendar birthdays: `CalendarSource` (EventKit), `NSCalendarsFullAccessUsageDescription`, source merge (Contacts wins), Settings toggle, importer maps `SystemContact.birthday` (closing the fetched-then-dropped gap) | Calendar-only birthday appears in Upcoming; revoking permission degrades gracefully |

### Phase 2 — Widget, monetization, polish (Aug 3–14)

| PR | Scope | Key acceptance criteria |
|---|---|---|
| **PR31** | Widget target: `RegardsWidget` in project.yml, App Group (`group.com.consideratesoftware.regards`), DB relocation to group container (+ migration of existing store), read-only widget queries, small/medium/lock variants, `reloadAllTimelines()` after SchedulingPass | Widgets live on device; app-group migration preserves data across update |
| **PR32** | StoreKit 2: entitlement service (`Platform/Billing`), trial state machine (`trialStartedAt`), Paywall screen, soft-lock on expiry (read-only + banner, never data loss), tip jar, Restore, StoreKitTest suite | Sandbox purchase/restore/expiry all pass; zero StoreKit imports outside `Platform/Billing` + Paywall |
| **PR33** | Settings completion: export JSON, delete-everything (+ confirmation), support mailto with diagnostics, Behind-the-App link, entitlement card | Export produces valid JSON of all 6 tables; delete returns to onboarding |
| **PR34** | Accessibility + visual hardening: fix sensory findings (ScaledMetric on fixed-size glyphs, contrast leftovers, hit regions), flip audit to **all** categories, snapshot tests (9 screens × states) + CI job, Dynamic Type pass to accessibility5 | Full-category audit green ×5 stress runs; snapshot job gating |
| **PR35** | Localization scaffolding (String Catalog, en at launch), 5k-contact performance pass (move CNContact enumeration off the cooperative pool, R25), final copy pass | Cold start <2s with 5k contacts on an A15 device |

### Phase 3 — Submission & launch (gate-based; legacy Aug 17–31 window retired)

- **Internal gate:** build 1.0.0 after `TESTFLIGHT_PLAN.md`'s `TF-08`; run the
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
| 9 | Android: no `INTERNET` permission; iOS: ATS-deny + no networking code | 2026-04-15 | Kernel-enforced guarantee on Android; verifiable-by-source on iOS. |
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

## 17. Working rules for implementation agents

**Reading order for any new session:** §18 → §19 → §14 (find your PR) → the spec sections your PR touches → this section. If your task contradicts this doc, stop and say so — either the task is wrong or this doc needs a sibling change in the same PR.

**The sibling-PR rule (inherited from CLAUDE.md, still absolute):** when code and this document disagree, one of them is wrong; fixing code without updating the doc (or vice versa) is an incomplete PR. Every feature PR cites the §s it implements.

**Definition of done for every PR:**
1. `cd ios && xcodegen generate` — commit `project.yml` *and* the regenerated xcodeproj (CI diffs them).
2. `swiftlint --strict` clean.
3. Full test action green locally: `xcodebuild -project Regards.xcodeproj -scheme Regards -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test`.
4. UI/test-code touched → `ios/scripts/audit-stress.sh` (5×) green.
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

## 18. Current state — ground truth as of 2026-07-29

`main` = `63a4f0f` (GitHub PR #21, 2026-07-29). The engine contract,
section-header accessibility fix, sample-data refresh, generic multi-agent
review infrastructure, channel-validation contract, and bundle-namespace
migration have landed. There are no open GitHub pull requests or issues.
`TESTFLIGHT_PLAN.md` records the next executable work.

### What exists and works (Phase 0 complete, PRs #1–#5)

- **Domain layer, pure and tested:** all §7 entities; `ReminderEngine` (cadence walk, quiet hours, annual recurrence + Feb-29, batching helper); `DuplicateDetector`; `ChannelCatalog` + `DeepLinkBuilder` for all 13 channels; `MonthDay` with round-trip validation.
- **Data layer, tested, dormant:** GRDB `v1` migration (all 6 tables + indexes + singleton seeds), records, 6 repository implementations, `DatabaseFactory` (file-protected prod DB + in-memory test DB), actor-backed `MockRepositories`.
- **9-screen SwiftUI shell** on mock data with real `@MainActor @Observable` VMs for Overdue/Upcoming/ContactDetail/MergeDuplicates; per-tab `NavigationStack`; fresh-VM-per-push factory (regression-tested); design system with WCAG-verified palette pairs.
- **Accessibility harness that gates merges:** 13 XCUI audit tests (structural categories), audit-stress tooling (script + workflow), documented test patterns and smoke script.
- **CI: 4 gating workflows** — ios-ci (xcodegen determinism → build → unit+coverage), guards (privacy-grep, domain-purity, YAML, ios/docs link check), lint (`--strict`), and the trusted hosted staged review, bound in branch protection on 2026-08-02 as `Regards staged review` and pinned to the dedicated App's identity so a same-repo Actions job cannot forge it. That fourth gate asserts a valid review ran for the current head, not that the reviewer approved: a missing, malformed or stale-head artifact fails it; a `REQUEST_CHANGES` verdict publishes its blockers in the check output and passes, leaving the call to the author. The accessibility audits (1× and 5×) moved off the PR path the same day and are release-blocking, not merge-blocking (§10).
- **Privacy posture in place:** ATS pinned, empty `LSApplicationQueriesSchemes`, `PrivacyInfo.xcprivacy` (tracking=false, nothing collected), read-only Contacts usage string, zero networking call sites (verified with CI's own pattern).

### What exists but is dormant (Phase 1 fragments, PRs #9–#10)

- `AppEnvironment.makeProduction` + `DatabaseFactory.makeDatabase()`: **zero callers.** `@main` injects `makeMock()` (`RegardsApp.swift:7`).
- `CNContactsSource` + `ContactsImporter` (additive first-import only): **zero app callers**; exercised by 13 unit tests. Fetches birthdays, then drops them in mapping.
- Of 6 injected repositories the UI reads **2** (`contacts`, `interactions.fetchRecent`); `reminders`, `window`, `profile`, `groups` have no UI consumers. No interaction is ever written (`append` uncalled). No `ScheduledReminder` row is ever created. No notification is ever scheduled. No deep link is ever opened.

### What is broken (fix before building — full detail in §19)

Headline open P0s: Edit Contact is a navigation trap; Reminder Windows is display-only; Upcoming ignores persisted reminders; merge and onboarding flows do not persist.

### What does not exist at all

SchedulingPass, notifications, deep-link execution, reconciliation/re-import, write-back, merge persistence, onboarding-in-launch-path, calendar ingestion, window persistence, widgets, StoreKit/paywall/trial, export/delete, snapshot tests, App Store listing metadata (name/bundle/SKU reserved 2026-04-15: `Regards: Stay in Touch`, `com.consideratesoftware.regards`, `regards-ios` — fields empty otherwise).

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
| R9 | **Reminder windows are fiction in the UI:** `UpcomingViewModel` hardcodes `.defaultV1()` ignoring `env.window` AND per-contact overrides; ReminderWindows screen renders `defaultV1()` display-only with a `.constant` Toggle | `UpcomingViewModel.swift:32,127`, `ReminderWindowsScreen.swift:7,226` | Live editor + repository read/write + override resolution in SchedulingPass (§9) | PR23 |
| R10 | **Upcoming re-derives on the fly** instead of reading persisted reminders reactively (§9 promised an indexed read + stream) | `UpcomingViewModel.swift:118-146` | `ValueObservation` over `ScheduledReminder ⋈ Contact` | PR25 |
| R11 | **Placeholder strings/stubs shipping in real screens:** hardcoded "Today, 6:30 pm" next-reminder; "next digest at 6:00 pm"; inert Horizon + "All" nav actions; no-op Caught up/Snooze/Log-other (factory passes no callbacks); no-op channel taps `{ _ in }`; inert Merge "Skip"; no-op Onboarding permission button | `ContactDetailScreen.swift:263-266` , `OverdueViewModel.swift:29`, `UpcomingScreen.swift:26`, `OverdueScreen.swift:33`, `RegardsApp.swift:102,169-177`, `MergeDuplicatesScreen.swift:108`, `OnboardingScreen.swift:4` | Each stub wired or removed by the PR owning its screen; **zero inert interactive controls at Phase 2 exit** (§10 rule) | PR22–PR29 |
| R12 | **Merge never persists** (no `ContactGroup` written; `env.groups` unused) and detector sees only `preferredChannelValue` instead of full handle sets | `MergeDuplicatesViewModel.swift:44-55` | PR28 scope + `phonesJson`/`emailsJson` inputs | PR28 |
| R13 | **Edit Contact navigation trap:** back button hidden + default no-op Cancel/Save closures at every push site → user is stuck | `EditContactScreen.swift:36, 8-14`; `RegardsApp.swift:108-110,125-127,135-137` | Never-hidden escape route; real form lands in PR27; audit test added (see R16) | PR27 (interim fix acceptable in PR18) |
| R14 | **Onboarding not in launch path** (single screen, Settings-preview only; `onboardingCompletedAt` never consulted) | `OnboardingScreen.swift`, `RegardsApp.swift:23-40` | 3-screen flow gated at launch per §10.8 | PR29 |
| R15 | **Transparency screen's 3 "Open" links inert**; repo URL hardcoded — verify before launch | `TransparencyScreen.swift:123, 183-187` | Wire `openURL`; confirm `github.com/sid78669/RegardsMobileApp` is the public repo URL | PR33 |

### P1 — spec/doc integrity

| R | Defect | Where | Fix | PR |
|---|---|---|---|---|
| R16 | Edit Contact missing from the audited-screens table AND the audit suite (violates accessibility.md rule 10) | `ios/docs/accessibility.md:76-89`, `ScreensAccessibilityTests.swift` | Add row + test | PR18 |
| R17 | `NSContactsUsageDescription` is read-only copy; §11 requires the edit mention before write-back ships. `NSCalendarsFullAccessUsageDescription` absent (needed PR30) | `project.yml:84-86` | Reword with PR27; add calendar key with PR30 | PR27/PR30 |
| R18 | `PrivacyInfo.xcprivacy` has empty `NSPrivacyAccessedAPITypes`; SQLite/GRDB file-timestamp access will need required-reason entries at submission | `ios/Regards/PrivacyInfo.xcprivacy` | Populate against Apple's current category list during Phase 3 prep | PR34/§20 |
| R19 | README references nonexistent `docs/DOMAIN_MODEL.md` and `android/`; root markdown exempt from link check so CI can't catch it | `README.md:52,54`; `guards.yml:60-69` | Fix README (decision #24); extend link check to root `*.md` | PR18/PR19 |
| R20 | **CLAUDE.md misroutes agents (5 stale claims):** iPhone 15 destinations (CI uses 16 Pro); "Platform/ currently empty" (has Contacts adapter); PrivacyInfo said to live in `Resources/`; `pr3AuditCategories`/"PR3 follow-ups" naming (actual: `structuralAuditCategories`, "Sensory-audit carve-outs"); "snapshot job declared `if: false`" (it's a comment, no job) | `CLAUDE.md:37,41,78,80,92,111` | Rewrite (done in the same change set as this doc v1.0); future edits follow sibling-PR rule | PR18 |
| R21 | `Package.resolved` gitignored while GRDB floats `from: 6.29.0` — contradicts reproducible-build claim | `.gitignore:32`, `project.yml:41-44` | Decision #37: commit it | PR19 |
| R22 | `RegardsUITests` placeholder target in no scheme/workflow; `PlaceholderTests.swift` in unit bundle | `ios/RegardsUITests/`, `RegardsTests/PlaceholderTests.swift` | Delete placeholders; keep the target only if PR34 snapshot/UI flows use it | PR19/PR34 |
| R23 | Mock and GRDB repositories share no contract tests — mocks can drift from production semantics | `RegardsTests/Data/RepositoriesTests.swift` | Shared contract-test suite run against both | PR20 |
| R24 | No unit tests for Upcoming/ContactDetail/MergeDuplicates VMs | `ios/RegardsTests/Features/` | Add with the PRs that touch each VM | PR22/PR25/PR28 |
| R25 | `CNContactsSource.fetchAllContacts` blocks a cooperative-pool thread for the full enumeration (5k-contact stall); `@unchecked Sendable` justified only by comment | `ContactsSource.swift:69, 98-125` | Move enumeration off the pool; 5k-contact perf test | PR35 |
| R26 | Force-unwrapped calendar math in the engine (`date(byAdding:)!`) | `ReminderEngine.swift:162,203-205` | Eliminated by the R1 rewrite (incl. `resolveFeb29Fallback`) | ✅ **closed by PR16** |
| R27 | accessibility.md documents `waitForContactDetailReady` as canonical — the helper was reverted in PR #12 and doesn't exist | `ios/docs/accessibility.md:166-175` | Correct to the plain-identifier wait actually in use | PR18 |
| R28 | Simulator name drift: iPhone 15 (CLAUDE.md, docs), 15 Pro (`audit-stress.sh:25`), 17 Pro (CI) | multiple | Standardize on iPhone 17 Pro | PR18 |
| R29 | Unmerged `origin/ios/section-header-accessibility-label` (+7 lines) likely fixes the known ~20% "Label not human-readable" audit flake | branch | Merge; then 3× audit-stress to confirm flake death | PR18 |

### P2 — hygiene / hardening

| R | Item | Where | Fix | PR |
|---|---|---|---|---|
| R30 | Stale worktree with obsolete parallel scaffold (`generate_pbxproj.py`, old Domain, committed `.xcuserstate`) + prunable branch `claude/crazy-franklin-75fc28` + stray `.git/t9FBrGy` + ~16 merged local branches | `.claude/worktrees/`, `.git/` | `git worktree prune`, delete branches, rm temp file | PR19 |
| R31 | Domain coverage floor absent (§13 promises near-total); coverage collected but unenforced | `ios-ci.yml:99-148` | ≥95% xccov gate on `Domain/**` | PR19 |
| R32 | Guard gaps: domain-purity misses `@preconcurrency import` / `import class Contacts.X` / `import Network`; privacy-grep misses `NSURLConnection`, `CFSocket` | `guards.yml:33,46` | Shared source-boundary scripts reject every listed form, and canonical plus trusted-review workflows call those scripts | ✅ **closed by TF-01 trusted gate prerequisite (GitHub PR #26)** |
| R33 | Dead SwiftLint config: `function_body_length` threshold block while the rule is disabled | `.swiftlint.yml:12-21,53-55` | Remove block or re-enable rule | PR19 |
| R34 | Mock seeds miss ContactGroup/InteractionLog/occasion — merged chip, interactions card, occasion tags unreachable & unauditable; `UpcomingRowState.id = UUID()` per build breaks diffing (R36) | `MockRepositories.swift:47-143`, `UpcomingViewModel.swift:130` | Seed all three; stable ids `contactId+kind` | PR19/PR22 |
| R35 | Importer aborts mid-batch on first row error | `ContactsImporter.swift:56-64` | Per-row tolerance + counts | PR21 |
| R36 | (folded into R34) | — | — | PR22 |
| R37 | `LSApplicationQueriesSchemes: []` while builder already emits `discord://` | `project.yml:80`, `DeepLinkBuilder.swift:43-45` | Add `discord` when deep links go live | PR26 |
| R38 | `TimeOfDay` precondition bypassed by synthesized `Decodable` — corrupt DB JSON can materialize minute=2000 into calendar math | `TimeOfDay.swift:10-13` | Custom `init(from:)` enforcing range | ✅ **closed by PR16** |
| R39 | Migrator seeds `Optional` top-level JSON (`jsonStringEncoded(window.quietHours)`) — inserts `"null"` / throws if the default ever ships nil quiet hours | `DatabaseMigrator.swift:106,124-129`, `Records.swift:247-248` | Encode non-optional or store SQL NULL | PR20 (with v2) |
| R40 | Unused asset colorsets (`Ink`,`Muted`,`Background`) + two comments describing a code↔xcassets sync that doesn't exist | `Resources/Assets.xcassets`, `RegardsColors.swift:9-11`, `accessibility.md:50-52` | Delete or wire; fix comments | PR19 |
| R41 | Contrast registry incomplete vs UI reality (white-on-accentInk CTAs, accentInk-on-surface, danger-on-surface unlisted) | `RegardsColors.swift:70-83` | Extend `contrastPairs` + tests | PR34 |
| R42 | `audit-stress.yml` header comment claims path-triggering that PR #15 removed | `audit-stress.yml:3-4` | Fix comment | PR19 |
| R43 | Stale smoke-doc step ("Phase 0 scaffold" splash subtitle that no longer exists) | `accessibility-smoke.md:19-21` | Update script | PR18 |
| R44 | `LSApplicationCategoryType` = social-networking in project.yml while the listing plan says Productivity primary | `project.yml:94` | Align with §20 category decision | PR34 |
| R45 | 8.4 MB `Substack_banner.png` sitting at repo root (ignored but clutter); `.DS_Store` files | repo root | Move banner to journal assets outside the repo; OS files stay ignored | anytime |
| R46 | `InteractionLog` doc comment references nonexistent `ContactRepository.markCaughtUp` API; `Channel.isAvailableOnIOS` always-true dead code; `Contact.effectiveWindow` misleading zero-caller helper | `InteractionLog.swift:11-12`, `Channel.swift:44`, `Contact.swift:58` | Fix comment; keep `isAvailableOnIOS` only if Android port will flip it (document), else delete; delete or repoint `effectiveWindow` at SchedulingPass | comment ✅ **closed by PR16**; `isAvailableOnIOS`/`effectiveWindow` → PR22 |
| R47 | Invalid persisted timezone identifiers silently fall back to the device timezone, changing reminder timing without consent | `ReminderWindow.swift`, `Records.swift` | Validate IANA identifier and reject malformed persisted windows | ✅ **closed in PR16 review** |
| R48 | Slot-start snapping can schedule a future-due contact before `overdueAt`; repeated-hour snapping can choose a boundary from the wrong UTC occurrence | `ReminderEngine.swift` | Distinguish already-overdue from future-due targets; resolve fall-back boundaries relative to the search instant; regression tests | ✅ **closed in PR16 review** |

## 20. Release engineering & App Store playbook

### Versioning & branching

- `main` is always releasable; feature branches → PR → squash-merge. Version
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
13. Copyright `© 2026 Siddharth Dahiya`. Trade rep info (Korea) skip unless targeting KR at launch.
14. Pricing: Tier-A $4.99 anchor + auto-pricing per storefront per §4 tiers; verify IN/BR land ₹99-class/R$9.90-class. IAPs: `com.consideratesoftware.regards.unlock` (non-consumable), `.tip.coffee`, `.tip.thanks`, `.tip.feature` — created, localized, attached to the submission build. **Small Business Program enrollment confirmed before launch.**
15. App Review notes: no account needed; no demo credentials; "This app contains no networking code by design (ATS denies all loads; source is public at github.com/sid78669/RegardsMobileApp). You will observe zero outbound traffic. Contacts write access is used only for user-initiated single-field edits."

### Pre-submission verification (run at freeze AND at submission)

1. Full CI green on the release SHA; audit-stress 5/5 ×3.
2. Fresh-install device pass: onboarding → permission grants AND denials → import → windows edit → notification fires in-window → deep link opens → caught-up → digest → widget → purchase (sandbox) → restore → export → delete-everything.
3. **Network capture session (Proxyman on device): zero outbound flows** outside StoreKit/OS. Record it — this becomes the §11 transparency video.
4. `PrivacyInfo.xcprivacy` required-reason entries verified against Apple's current list (R18).
5. VoiceOver full-flow smoke; Dynamic Type accessibility5 spot pass.
6. DB migration test from a v1-schema store (simulating a Phase-0-era TestFlight install upgrading).
7. Archive builds reproducibly from a clean checkout (`xcodegen generate && xcodebuild archive`).

### Rejection playbook

Most likely flags for this app: (a) **2.1 performance/completeness** — reviewer can't see reminder value quickly → the review notes include a 60-second "how to see a reminder fire" script (set cadence 1 day, window = now); (b) **5.1.1 permission purpose strings** — keep strings specific (R17); (c) **privacy label mismatch** — we collect nothing, labels say so, PrivacyInfo agrees; (d) IAP restore/trial confusion — Restore button visible in Paywall AND Settings. Respond in Resolution Center within 24h; if metadata-only, fix without re-review; never argue, clarify.

### Launch-day runbook

Release the approved build manually at ~9am ET → verify live in 2–3 storefronts → publish journal post #10 (launch) → Product Hunt launch → press emails (MacStories, Privacy Guides forum, 9to5Mac tips, r/privacy where rules allow) with the press kit (one-pager, screenshots, network-capture video link, source link) → pin the GitHub Discussions welcome thread → watch crash/feedback channels; hotfix bar is P0-only for week 1.

## 21. Maintenance & operations playbook

**Weekly (steady state):** triage GitHub Issues + store reviews (respond to every review, year 1); check TestFlight/App Store crash reports (organizer); scan support inbox; merge dependabot-equivalent manual checks — GRDB releases reviewed, bumped deliberately with `Package.resolved` diff + full test pass (never auto-bump; decision #37).

**Per release (any version):** the §20 pre-submission verification list, scaled to change size; sibling doc updates; refreshed Exodus report (Android, once it exists) and network-capture spot check; tag + release notes; journal post if user-visible.

**Quarterly (year 1):** geo-tier pricing review vs FX drift (document in a journal post per §15.6); competitive-landscape refresh of the §4 table; accessibility re-audit with the newest Xcode audit categories; dependency + toolchain review.

**OS-beta season (June–September, annually):** from WWDC beta 1, run the full suite + manual smoke on each beta of iOS N+1; fix deprecations before GM; re-verify ATS/privacy-manifest behavior changes and the Contacts/EventKit permission UX (Apple reshapes these regularly — iOS 17 did for Calendar; iOS 18 did for Contacts with the limited-access picker: **test limited-Contacts-authorization mode explicitly**, it's the likeliest silent breaker for this app; if `CNAuthorizationStatus.limited` exists in the target SDK, the importer and reconcile paths must handle a partial universe without archiving unseen contacts — add that test before the first fall-OS release).

**Incident response (no telemetry by design, so signals are humans):** crash spike = App Store crash organizer + review keywords + support mail. Reproduce → hotfix branch from the release tag → expedited review request if P0 (data loss / notifications dead / launch crash). The user-initiated diagnostic mailto is the only "log" pipeline; keep its payload useful (app version, OS, device, last-migration id, counts — never contact data).

**Data-integrity guarantees:** any future migration `vN` ships with an upgrade test from every prior shipped schema; export format is versioned (`"exportVersion": 1`) and import-tested (V2 sync candidate depends on it); "Delete everything" must remain instant and total.

**Community/comms:** journal cadence per §11b (biweekly floor, event posts on milestones); roadmap board updated when scope decisions happen, not after shipping; V2 candidates graduate only through a decisions-log entry with a scope cut somewhere else — the UpHabit scope-creep lesson is standing policy.

**Android start gate (from §14):** iOS crash-free ≥99.5% over 2 trailing weeks, support <30 min/day, and the §19 register at zero open P0/P1. Then the port begins with the domain test suite translation, not with UI.

---

*End of document.*
