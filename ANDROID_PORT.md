# ANDROID_PORT.md — Android architecture and execution queue

**Role of this file.** `ARCHITECTURE.md` remains the product and technical
source of truth for both platforms; nothing here overrides it. This file owns
only what is Android-specific: the module graph, the Gradle and CI
conventions, the port map from the Swift codebase, the parity mechanism, and
the `AN-##` execution queue. It mirrors the split the repo already uses:
`ARCHITECTURE.md` is truth, `TESTFLIGHT_PLAN.md` is the iOS queue, this file
is the Android queue. When this file and `ARCHITECTURE.md` disagree,
`ARCHITECTURE.md` wins and this file needs a sibling fix (§17 rule).

**Start-gate carve-out (decision #41).** §14/§21 gate the Android track on
iOS health: crash-free ≥99.5% over 2 weeks, support < 30 min/day, §19 at zero
open P0/P1. That gate is deliberately **not** met today. Decision #41 permits
exactly this much ahead of the gate: architecture (this file), the `android/`
scaffold, the Android CI guards, and the shared golden-vector test
infrastructure (AN-00–AN-02). Kotlin domain porting and everything after it
stays behind the gate unless the owner explicitly promotes an item in the
queue below. The carve-out exists so the gate stays honest while the
groundwork stops being blocking.

Read `AGENTS.md` first, then `ARCHITECTURE.md` §18 → §19 → §14, then this
file. The restart protocol in `TESTFLIGHT_PLAN.md` applies to `AN-##` items
verbatim, substituting this file's queue for the TF table.

---

## A1. Stack (binding, from §6)

Kotlin 2.x · Jetpack Compose + Material 3 · Room + SQLCipher (key material in
Android Keystore) · Coroutines/Flow · `NotificationManagerCompat` +
`AlarmManager.setExactAndAllowWhileIdle` with `SCHEDULE_EXACT_ALARM`
(WorkManager fallback when exact alarms are refused; 5–15 min drift is
acceptable per §9) · `ContactsContract` · `CalendarContract` · Play Billing 7
· **min SDK 28**, compile/target latest stable.

Consequences the scaffold already bakes in:

- min SDK 28 means `java.time` is available natively (no desugaring).
  Domain time math uses `java.time` (`ZonedDateTime`, `ZoneId` rules) —
  the wall-clock semantics §9 demands, never epoch-plus-seconds arithmetic.
- **No Hilt/Dagger/Koin.** DI is manual, mirroring iOS `AppEnvironment`: one
  environment object built at the `Application`/root-composable boundary,
  holding the six repository interfaces, with `makeMock()` and
  `makeProduction(db)` constructors. Zero codegen, fewer dependencies to
  audit — this is the reproducibility posture (§11, decision #37) applied to
  DI. If manual wiring ever hurts, that is a recorded decision, not a drive-by.
- Version catalog pins **exact versions** (no ranges), and AN-01 adds Gradle
  dependency-verification metadata plus a pinned wrapper checksum. This is the
  R21 / `Package.resolved` lesson: an app whose privacy story is "audit the
  source" ships reproducible builds on both platforms.

## A2. Module graph (from §12)

```
:app                     @main analog: Application, RegardsEnvironment (DI), 4-tab shell, navigation
:domain                  PURE KOTLIN (org.jetbrains.kotlin.jvm). Port of ios/Regards/Domain. JVM unit tests.
:data                    Room records, migrations, repository implementations, MockRepositories.
                         Repository INTERFACES also live here (parity with ios Data/Repositories.swift).
:designsystem            RegardsDS tokens (color incl. contrast pairs, type, spacing) + primitives
                         (Avatar, ChannelGlyph, Tag, Wordmark, RegardsSegmentedControl).
:feature:overdue         One module per screen, mirroring ios/Regards/Features/ exactly:
:feature:upcoming        overdue, upcoming, contacts, contact-detail, edit-contact,
:feature:contacts        merge-duplicates, onboarding, settings, paywall.
:feature:contact-detail  Each owns its Screen composable + ViewModel.
:feature:edit-contact
:feature:merge-duplicates
:feature:onboarding
:feature:settings
:feature:paywall
:platform:contacts       ContactsContract source + importer (lookup-key based).
:platform:calendar       CalendarContract occasion source.
:platform:notifications  NotificationScheduling impl, channels, boot/timezone receivers.
:platform:deeplinks      Intent.ACTION_VIEW + resolveActivity fallback (§8).
:platform:billing        Play Billing; entitlement mapping. The ONLY module that may import billing.
:widget                  Glance widgets (small/medium + lock-screen-analog), Phase 2 parity.
```

Dependency rules (enforced by guards, see A4):

- `:domain` depends on **nothing** but the Kotlin stdlib, `kotlinx.coroutines-core`,
  and (test-only) `kotlinx-serialization` for golden vectors. No `android.*`,
  no `androidx.*`, no Room, no Compose. This is §5 domain purity, Kotlin edition.
- `:feature:*` depend on `:domain`, `:designsystem`, and the repository
  interfaces in `:data`. They must not import `androidx.room.*` — repository
  interfaces are the boundary, exactly like `any *Repository` on iOS.
- `:platform:*` are the only modules that touch their respective OS APIs;
  `:app` composes everything. `:data` is the only module importing Room/SQLCipher.
- `:app` is the sole owner of `SchedulingPass` (§9a): the one writer of
  `ScheduledReminder` rows and OS notifications on Android too. Everything
  else reads. Do not port any feature to write reminders directly.

## A3. Port map

| iOS (source of truth) | Android target | Notes |
|---|---|---|
| `Domain/Contact`, `ScheduledReminder`, `InteractionLog`, `UserProfile`, `ReminderWindow`, `TimeOfDay`, `DayOfWeek`, `PriorityTier`, `Channel` | `:domain` `com.sdahiya.regards.domain` | Same names, same invariants. Value types → `data class`/`enum class`/`value class`. |
| `Domain/Reminders/ReminderEngine` | `:domain` `reminders/ReminderEngine.kt` | §9 contract verbatim: `Instant?` return (nil-able slot), wall-clock via `ZonedDateTime`, slot-start snapping, `?? createdAt` anchor, same-day-late occasions, no-double-up. |
| `Domain/Reminders/DuplicateDetector` | `:domain` `reminders/DuplicateDetector.kt` | Same heuristics: normalized name, last-10-digit phone key (decision #25), lowercased email; confidence phone > email > name (decision #26). |
| `Domain/Channels/ChannelCatalog`, `DeepLinkBuilder` | `:domain` `channels/` | `isValid(v) ⟹ build(v) != null` property holds per channel (decision #27). Platform availability becomes per-platform data: FaceTime unavailable on Android (closes the R46 question — the flag stays and flips). |
| `Data/Repositories.swift` (6 protocols) | `:data` `Repositories.kt` (6 interfaces) | `ContactRepository`, `ContactGroupRepository`, `ReminderRepository`, `InteractionRepository`, `ReminderWindowRepository`, `UserProfileRepository`. Same names, `suspend`/`Flow` signatures. |
| `Data/Records`, `DatabaseMigrator`, `DatabaseFactory` | `:data` Room entities + `RegardsDatabase` | Android schema v1 = iOS §7 v1 **plus** the v2 columns (`phonesJson`, `emailsJson`, `occasionTime`, `digestHorizonDays`, `trialStartedAt`) — no shipped Android users, so no reason to replay iOS migration history. Same tables, columns, indexes; Room `exportSchema = true` with schemas committed. Do not index `systemContactRef` (unique covers it). |
| `Data/MockRepositories` | `:data` `MockRepositories.kt` | Same seed cast, **including** `ContactGroup`/`InteractionLog`/occasion rows — the §18 mock-drift lesson; contract tests bind mocks to Room impls from day one. |
| `App/AppEnvironment` | `:app` `RegardsEnvironment.kt` | `makeMock()` / `makeProduction(db)`; production flip is one line at the root, mock path survives behind a launch flag for tests/previews. |
| `App/RegardsNavigation` (4 tabs, per-tab `NavigationPath`) | `:app` navigation | Per-tab back stacks; a push in Overdue must not bleed into Upcoming. ContactDetail gets a fresh VM per push (factory, not composition identity). |
| `DesignSystem/` | `:designsystem` | Port tokens + WCAG contrast pairs; Material 3 theming maps onto `RegardsDS`, not the other way around. |
| `Features/*` (9 screens) | `:feature:*` | Screen + ViewModel per module. Zero inert interactive controls (§10 hard rule) applies from the first composable. |
| `Platform/Contacts/ContactsSource`+`Importer` | `:platform:contacts` | `systemContactRef` = ContactsContract **lookup key** (stable), not raw contact id. Per-row fault tolerance (R35). Reconcile on launch/foreground/change: new → `tracked=false`; deleted → `archivedAt` (never hard-delete); changed → refresh fields. Write-back only via partial-field `ContentProviderOperation` batches (§7: never delete, never bulk-edit, never merge system contacts). |
| `UNUserNotificationCenter` scheduling (PR24–25, not yet built on iOS) | `:platform:notifications` + `SchedulingPass` in `:app` | See A5 — Android has real deltas here. |
| StoreKit 2 (PR32, not yet built) | `:platform:billing` | Entitlement enum exactly `free | trial | lifetime`; soft-lock = read-only + banner, never data loss. "Zero billing imports outside `:platform:billing` + paywall" is the acceptance, same as iOS. |

**What the port reference actually is.** Per §14 and the §18 findings: the
iOS *production loop does not exist yet* (no SchedulingPass, notifications,
deep-link execution, write-back, merge persistence, billing). The executable
contract is `ios/Regards/Domain/` + `ios/RegardsTests/Reminders/` and the §7/§9/§9a
spec. Port from the spec and the tests, not from unshipped iOS scaffolding —
and where iOS hasn't wired something yet (R9, R10, R12, R14), Android does it
right the first time instead of reproducing the dormant-layer mistake.

## A4. Privacy and layer guards (the marquee artifact)

**No `android.permission.INTERNET`, ever.** §11 nuclear tier: the merged
manifest must not contain `INTERNET` or `ACCESS_NETWORK_STATE`. The kernel
then denies socket creation to the app's UID — stronger than any code audit.
Play Billing still works (runs in Google Play's process, not ours).

Defense in depth, all landed in AN-00:

1. `app/src/main/AndroidManifest.xml` carries
   `<uses-permission android:name="android.permission.INTERNET" tools:node="remove"/>`
   so a permission injected by any library manifest is stripped at merge time.
2. `scripts/check-android-manifest.sh` — CI grep: no manifest under `android/`
   may *declare* INTERNET/ACCESS_NETWORK_STATE, and the `tools:node="remove"`
   line must stay present in the app manifest.
3. `scripts/check-android-no-network.sh` — CI grep over `android/` sources for
   networking call sites: `HttpURLConnection`, `java.net.Socket`/`ServerSocket`/
   `DatagramSocket`/`InetAddress`, `okhttp3`, `retrofit2`, `io.ktor`,
   `android.webkit.WebView`, `SocketChannel`. Same posture as the iOS
   privacy-grep; WebView is included because remote content is a network
   vector even without our own sockets.
4. `scripts/check-android-domain-purity.sh` — `:domain` sources may not import
   `android.*`, `androidx.*`, `java.net.*`, or Room/Compose/SQLCipher.
5. AN-01 adds a **merged-manifest** check (a Gradle verification task that
   fails the build if the post-merge manifest contains either permission) —
   the source-level grep in (2) is the fast guard, the merged check is the
   airtight one. AN-01 also adds fixture tests for scripts 2–4 under
   `scripts/tests/` (R32 lesson: untested guards grow holes).

Release-time artifacts (queue items, not afterthoughts): Play Data Safety =
"no data collected, no data shared"; an Exodus Privacy report per release;
reproducible-build documentation in-repo. F-Droid is out (PolyForm
Noncommercial, journal post 07).

Encryption at rest: SQLCipher with a random passphrase generated on first
launch, wrapped by an Android Keystore key (StrongBox where available).
`android:allowBackup="false"` + explicit `dataExtractionRules` in the
scaffold — see open question Q2 before flipping.

## A5. Android-only behavioral deltas (design now, build later)

These have no iOS analog and are where Android bugs will live:

- **Alarms don't survive reboot.** iOS `UNUserNotificationCenter` requests
  persist; `AlarmManager` alarms are wiped on reboot. `:platform:notifications`
  registers `BOOT_COMPLETED`, `TIMEZONE_CHANGED`, and `TIME_SET` receivers,
  each of which triggers `SchedulingPass.runFull()`. Idempotency (§9a) is what
  makes this safe.
- **Exact-alarm permission is deniable.** `SCHEDULE_EXACT_ALARM` can be
  refused or revoked (§15 open question 1: measure denial rate in beta). The
  fallback is WorkManager with a window; 5–15 min drift is acceptable, but the
  *never fire outside the reminder window / quiet hours* promise still binds —
  the fallback schedules inside the slot with enough margin, or skips to the
  next slot. Firing late is acceptable; firing outside the window is not.
- **Digest batching maps to notification identity.** iOS IDs
  (`digest-{slotStartEpoch}`, `contact-{uuid}-{kind}`) become notification
  tag+id pairs and `PendingIntent` request codes derived the same way, so
  cancellation and reconciliation stay exact-match, and a digest updates in
  place rather than stacking.
- **Notification channels are user-controllable.** Two channels: cadence
  digests and occasions (at `occasionTime`). Users silencing a channel is the
  Android version of the "per-contact nags get silenced" insight — respect it,
  never route around a muted channel.
- **Doze/App Standby** delay inexact work. The digest slot-start model
  already tolerates this; document measured drift during beta rather than
  fighting the OS.
- **Contacts identity.** Lookup keys survive sync/merge churn better than row
  ids, but can still change; reconcile resolves by lookup key with a
  last-resort re-match pass (same fields the DuplicateDetector uses) before
  archiving a contact as deleted.
- **Touch targets are 48dp** on Android (44pt equivalent rule, §10). Icon-only
  buttons require `contentDescription` — enforced by Android Lint's built-in
  `ContentDescription` check promoted to error, the Compose analog of the
  custom `button_requires_accessibility` SwiftLint rule.

## A6. Parity: golden test vectors

`shared/testvectors/` (new, platform-neutral) holds JSON fixtures both test
suites consume. The Swift suite is the generator and first consumer; the
Kotlin suite consumes the identical files. Divergence fails CI on whichever
platform drifted. Scope, in priority order:

1. **Engine scheduling cases** — window config, quiet hours, IANA timezone,
   `now`, `lastInteractedAt`/`createdAt`, cadence → expected `scheduledFor`
   or `null`. Must include: DST spring-forward and fall-back **on weekday
   windows across multiple years** (the R1 lesson: 2026's US transitions are
   Sundays, and weekday-only tests dodged the bug), a half-hour-offset zone
   (e.g. Lord Howe), degenerate windows, wrap-attempt quiet hours, same-day-late
   occasions, slot-start snapping/batching, the `overdueAt` floor (R48).
2. **Duplicate-detector cases** — handle sets in, ranked pairs + confidence out.
3. **Deep-link cases** — (channel, value) → URL or null, both platforms'
   availability tables.
4. **Validation⟹construction cases** — every channel's `isValid ⟹ build ≠ null`.

Vector schema and the Swift generator land in AN-02 (it touches `ios/` —
additive test infrastructure only, no production code, and it pays iOS back
immediately: transition-day coverage is exactly what §18 found missing).
Everything else in the Kotlin domain port is a hand translation of the Swift
tests, kept honest by the vectors underneath.

## A7. Testing and CI

- `:domain`: plain JVM tests (fast), golden vectors + ported property tests
  (Kotest property module), **≥95% line coverage floor via Kover** — parity
  with the iOS Domain floor (R31).
- `:data`: Robolectric + Room in-memory for repository/migration tests;
  committed Room schemas make migration tests real from v2 onward.
- Contract tests run the same suite against `MockRepositories` and Room
  implementations (the §18 mock-drift lesson, structural this time).
- Compose: screen-level semantics tests + Accessibility Test Framework
  checks; TalkBack manual smoke doc (`android/docs/accessibility.md`) mirrors
  the VoiceOver smoke contract. Same flake discipline as iOS: reproduce ≥2/5
  before "fixing," prefer deleting cleverness over adding waits, stress runs
  live post-merge/nightly, not on PRs (decision #39).
- CI (`.github/workflows/android-ci.yml`, AN-01): **ubuntu runners** — the
  billed-macOS lesson (decision #39) doesn't get re-learned on Android. Jobs:
  build → `:domain` tests + Kover floor → lint (Android Lint + detekt) →
  guards. The three Android guard scripts are wired into `guards.yml` now
  (AN-00) so they run from the first commit that touches `android/`.
- Lint: Android Lint with `ContentDescription` as error; detekt + Compose
  rules; warnings-as-errors in CI, matching `--strict` posture on iOS.

## A8. Learnings applied (§18 → Android preventions)

| §18 finding | Android prevention |
|---|---|
| DST wall-clock bug + tests that dodged transition days (R1) | `java.time` zoned math only; vectors force weekday transitions, multiple years, half-hour zones |
| Degenerate window returned input date; no caller checked (R4) | `Instant?` from day one; editor validation refuses zero-capacity configs; Settings badge path in spec |
| Never-contacted semantics diverged between engine and VMs (R8) | Single anchor rule in `:domain`; divergence vector; consumers forbidden from re-deriving engine outputs (R49 lesson) |
| Batching by exact Date equality never batched | Slot-start snapping is in the vectors; notification identity derived from slot start |
| Fully built, fully dormant data layer; green tests over an unwired app | Queue order wires production env (AN-11) immediately after the shell; "dormant" is a blocked state, not a milestone |
| Inert controls shipped in real screens (R11) | §10 zero-inert rule inherited verbatim; every stub enumerated in the queue item that owns its screen |
| Mock drift, incomplete seeds | Contract tests bind mocks to Room impls; seeds include groups/interactions/occasions from AN-06 |
| CI guards had holes; guards now fixture-tested (R32) | Android guards get fixtures in AN-01; merged-manifest check backs the grep |
| Floating deps vs "audit the source" (R21) | Exact-version catalog + dependency verification metadata + pinned wrapper checksum |
| Schedule fiction (retired 2026-08-31 date) | AN queue has statuses and gates, no dates |
| Docs and code disagreed silently for two months | This file + sibling edits landed in the same PR as the scaffold; §17 sibling rule applies to `android/` |

## A9. Execution queue

Statuses and rules as in `TESTFLIGHT_PLAN.md` (`DONE / ACTIVE / READY /
BLOCKED / OWNER`; one item at a time; branch named after the ID; checkpoint
updated in the same PR). **Gate line:** items below it are BLOCKED on the
§21 iOS-health gate unless the owner promotes them by editing this table —
promotion is a recorded owner action, not an agent call.

| ID | Status | Depends on | Scope and exit evidence | Refs |
|---|---|---|---|---|
| AN-00 | ACTIVE | — | This file; `android/` scaffold (settings, catalog, convention plugins, all module stubs, no-INTERNET manifest with `tools:node="remove"`); Gradle wrapper committed (8.14.3, distribution SHA-256 pinned, wrapper jar verified against Gradle's published checksum); three guard scripts wired into `guards.yml`; sibling doc edits (AGENTS/README/ARCHITECTURE §6·§11·§16/TESTFLIGHT cross-ref). Exit: guards green; first sync on the owner's machine succeeds; PR merged. | §11, §12, decision #41 |
| AN-01 | READY | AN-00 | Build hardening: exact-version audit of the catalog (all `TODO(AN-01)` pins); dependency-verification metadata; merged-manifest Gradle check; fixture tests for the three guard scripts under `scripts/tests/`; `android-ci.yml` (ubuntu: build, `:domain` tests, Kover floor, lint). | R21, R32, dec. #37 |
| AN-02 | READY | AN-01 | Golden vectors: schema doc in `shared/testvectors/`; Swift generator target; iOS suite consumes vectors (additive, touches `ios/`); initial corpus per A6 incl. weekday-DST and half-hour-zone cases. | A6, R1, R48 |
| — | — | — | **— iOS-health gate (§21) — owner promotion required below this line —** | dec. #41 |
| AN-03 | BLOCKED | AN-02 | `:domain` entities + `ReminderWindow`/`TimeOfDay`/`DayOfWeek` + validation; vectors green on Kotlin. | §7 |
| AN-04 | BLOCKED | AN-03 | `:domain` `ReminderEngine`: full §9 contract; all engine vectors green incl. DST corpus. | §9, R1–R8 |
| AN-05 | BLOCKED | AN-04 | `:domain` `ChannelCatalog` + `DeepLinkBuilder` + `DuplicateDetector`; property tests (`isValid ⟹ build`); availability table flips FaceTime off. | §8, R46 |
| AN-06 | BLOCKED | AN-05 | `:data`: Room schema v1 (= iOS v1+v2 fields), committed schemas, six repositories, mocks with full seeds, mock↔Room contract tests. | §7 |
| AN-07 | BLOCKED | AN-06 | `:designsystem` tokens/primitives + `:app` shell: 4 tabs, per-tab back stacks, `RegardsEnvironment.makeMock()`. | §10, §12 |
| AN-08 | BLOCKED | AN-07 | Features on mocks, batch 1: Overdue, Upcoming, Contacts, ContactDetail. Zero inert controls. | §10 |
| AN-09 | BLOCKED | AN-08 | Features on mocks, batch 2: EditContact, MergeDuplicates, ReminderWindows, Onboarding, Settings(+Transparency), Paywall shell. | §10 |
| AN-10 | BLOCKED | AN-09 | Accessibility harness: ATF checks in CI, TalkBack smoke doc filled, 48dp/contentDescription lint gates proven, screens-audited table started. | §10 |
| AN-11 | BLOCKED | AN-10 | Production wiring: real DB, first-launch import + reconcile via `:platform:contacts`, onboarding in the launch path. No dormant layers. | R9, R14 |
| AN-12 | BLOCKED | AN-11 | `SchedulingPass` + `:platform:notifications`: exact alarms + WorkManager fallback, digest batching, boot/timezone/time-set receivers, reactive Upcoming. Exit includes airplane-mode device test. | §9a |
| AN-13 | BLOCKED | AN-12 | Deep links (`resolveActivity` + https fallback) + caught-up/snooze loop semantics (snooze moves `scheduledFor` only). | §8, dec. #31 |
| AN-14 | BLOCKED | AN-13 | Write-back (partial-field `ContentProviderOperation`), merge persistence + group-aware scheduling, calendar occasions. | §7, R12 |
| AN-15 | BLOCKED | AN-14 | Glance widgets (small/medium/lock-analog). | §12 |
| AN-16 | BLOCKED | AN-15 | Play Billing + entitlement state machine + trial + soft-lock (read-only + banner) + tip jar + restore. Billing imports confined to `:platform:billing` + paywall. | dec. #22-range, §13 |
| AN-17 | BLOCKED | AN-16 | Hardening: sensory a11y categories, 5k-contact perf, localization scaffold. | §10 |
| AN-18 | BLOCKED | AN-17 | Play release: Data Safety ("no data collected/shared"), reproducible-build doc, Exodus report, internal-testing track upload. OWNER gates: Play Console account, signing, listing copy. | §11 |

## A10. Open questions (owner)

1. **Exact-alarm denial rate** — §15 Q1; measure in beta, then decide whether
   the WorkManager path needs product copy.
2. **Backup posture.** Scaffold ships `allowBackup="false"` (nothing leaves
   the device, matching the privacy pitch) — but that means device migration
   loses Regards data unless we ship the §13 local export/import first. Keep
   false and make export the migration path, or scope `dataExtractionRules`
   to allow device-to-device only? Decide before AN-11.
3. **Play Billing major version** — §6 says Billing 7; re-verify current
   stable at AN-16 and pin then.
4. **Lock-screen widget analog** — Android has no 1:1 for the iOS Lock Screen
   count widget; decide Glance-on-lockscreen vs drop at AN-15.

---
*Created 2026-08-03 on branch `android/an-00-scaffold`, baseline `ade40e3`.
Sibling edits in the same commit: `AGENTS.md`, `README.md`,
`ARCHITECTURE.md` (§6 header, §11 guard note, decision #41),
`TESTFLIGHT_PLAN.md` (cross-reference).*
