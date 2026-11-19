// Glance widgets — Phase 2 parity (AN-15). Scaffold only.
plugins {
    id("regards.android-library")
}

android {
    namespace = "com.consideratesoftware.regards.widget"
}

dependencies {
    implementation(project(":domain"))
}
