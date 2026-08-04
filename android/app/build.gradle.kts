plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "com.sdahiya.regards"
    compileSdk = 36 // TODO(AN-01): verify

    defaultConfig {
        applicationId = "com.sdahiya.regards"
        minSdk = 28
        targetSdk = 36 // TODO(AN-01): verify
        versionCode = 1
        versionName = "0.1.0"
    }

    buildFeatures {
        compose = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    implementation(project(":domain"))
    implementation(project(":data"))
    implementation(project(":designsystem"))
    implementation(project(":widget"))

    implementation(project(":feature:overdue"))
    implementation(project(":feature:upcoming"))
    implementation(project(":feature:contacts"))
    implementation(project(":feature:contact-detail"))
    implementation(project(":feature:edit-contact"))
    implementation(project(":feature:merge-duplicates"))
    implementation(project(":feature:onboarding"))
    implementation(project(":feature:settings"))
    implementation(project(":feature:paywall"))

    implementation(project(":platform:contacts"))
    implementation(project(":platform:calendar"))
    implementation(project(":platform:notifications"))
    implementation(project(":platform:deeplinks"))
    implementation(project(":platform:billing"))

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.bundles.compose)
}
