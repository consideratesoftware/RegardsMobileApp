# Golden test vectors (seed — schema lands at AN-02)

Language-neutral JSON fixtures consumed by BOTH test suites
(`ios/RegardsTests` and `android/domain/src/test`). The Swift suite generates
and first-consumes them; the Kotlin port must produce identical outputs.
Divergence fails CI on whichever platform drifted. See `ANDROID_PORT.md` A6.

Planned corpora, in priority order:

1. `engine/` — scheduling cases: window config, quiet hours, IANA timezone,
   now, lastInteractedAt/createdAt, cadence → expected scheduledFor or null.
   Must include weekday DST transitions across multiple years, a half-hour
   zone, degenerate windows, slot-start snapping, the overdueAt floor (R48).
2. `duplicates/` — handle sets → ranked pairs + confidence.
3. `deeplinks/` — (channel, value) → URL or null, per-platform availability.
4. `channels/` — isValid ⟹ build ≠ null cases per channel.

Nothing here yet is normative; AN-02 defines the schema and the generator.
