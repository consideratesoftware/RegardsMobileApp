// Mirrors ios/Regards/Features — Screen composable + ViewModel per module.
// Zero inert interactive controls (§10). No androidx.room imports here —
// repository interfaces in :data are the boundary (ANDROID_PORT.md A2).
plugins {
    id("regards.android-feature")
}

android {
    namespace = "com.sdahiya.regards.feature.settings"
}

dependencies {
    implementation(project(":domain"))
    implementation(project(":designsystem"))
    implementation(project(":data"))
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.bundles.compose)
}
