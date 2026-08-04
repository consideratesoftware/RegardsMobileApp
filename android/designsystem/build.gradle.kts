// RegardsDS tokens (colors incl. WCAG contrast pairs, typography, spacing) and
// primitives (Avatar, ChannelGlyph, Tag, Wordmark, RegardsSegmentedControl).
// Material 3 maps onto RegardsDS, not the other way around (ANDROID_PORT.md A3).
plugins {
    id("regards.android-feature")
}

android {
    namespace = "com.sdahiya.regards.designsystem"
}

dependencies {
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.bundles.compose)
}
