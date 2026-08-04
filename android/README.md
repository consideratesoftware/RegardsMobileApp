# Regards — Android

Scaffold only (AN-00). Architecture, port map, and the `AN-##` execution queue
live in `../ANDROID_PORT.md`; product truth is `../ARCHITECTURE.md`. Feature
work is gated — see decision #41 before writing code here.

## Setup

- JDK 17+, Android Studio (or Android SDK + command line). No standalone
  Gradle needed — the wrapper is committed (Gradle 8.14.3, distribution
  SHA-256 pinned in `gradle/wrapper/gradle-wrapper.properties`; the wrapper
  jar matches Gradle's published `gradle-8.14.3-wrapper.jar.sha256`).

```bash
cd android
./gradlew :domain:test
```

AN-01 generates dependency-verification metadata; until then every version in
`gradle/libs.versions.toml` is marked `TODO(AN-01)`.

## Structure

17 modules per `ANDROID_PORT.md` A2: `:app`, `:domain` (pure Kotlin),
`:data` (Room + SQLCipher + repository interfaces), `:designsystem`,
9 × `:feature:*`, 5 × `:platform:*`, `:widget`. Conventions come from
`build-logic/` (`regards.kotlin-pure`, `regards.android-library`,
`regards.android-feature`).

## Non-negotiables

- **No `android.permission.INTERNET`, ever** (§11). The app manifest strips
  the permission at merge with `tools:node="remove"`; CI enforces via
  `scripts/check-android-manifest.sh` and `scripts/check-android-no-network.sh`.
- `:domain` stays pure Kotlin (`scripts/check-android-domain-purity.sh`).
- Feature modules never import Room; the repository interfaces in `:data`
  are the boundary.
- Exact dependency versions only; no ranges (decision #37).
