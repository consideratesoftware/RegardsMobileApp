// Play Billing. The ONLY module that may import billing (plus :feature:paywall UI). Entitlement enum: free | trial | lifetime.
plugins {
    id("regards.android-library")
}

android {
    namespace = "com.sdahiya.regards.platform.billing"
}

dependencies {
    implementation(project(":domain"))
}
