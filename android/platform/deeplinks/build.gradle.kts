// Intent.ACTION_VIEW with resolveActivity check and https fallback toast (§8).
plugins {
    id("regards.android-library")
}

android {
    namespace = "com.sdahiya.regards.platform.deeplinks"
}

dependencies {
    implementation(project(":domain"))
}
