// Convention for :domain — pure Kotlin/JVM (ARCHITECTURE.md §5, Kotlin edition).
// No android.*, androidx.*, Room, Compose, or java.net.* — enforced by
// scripts/check-android-domain-purity.sh in CI.
plugins {
    id("org.jetbrains.kotlin.jvm")
}

kotlin {
    jvmToolchain(17)
}
