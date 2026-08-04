// PURE KOTLIN. The port of ios/Regards/Domain — same names, same invariants
// (ANDROID_PORT.md A3). Time math is java.time zoned wall-clock, never epoch
// arithmetic (§9 / R1). Purity enforced by scripts/check-android-domain-purity.sh.
plugins {
    id("regards.kotlin-pure")
}

dependencies {
    implementation(libs.kotlinx.coroutines.core)

    testImplementation(libs.kotest.runner)
    testImplementation(libs.kotest.property)
    // Test-only: golden vectors under shared/testvectors (ANDROID_PORT.md A6).
    testImplementation(libs.kotlinx.serialization.json)
}

tasks.withType<Test>().configureEach {
    useJUnitPlatform()
}
